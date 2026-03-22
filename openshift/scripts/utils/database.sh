#!/bin/bash

# Database Utilities Module
# Contains Galera/MariaDB operations, health checks, and auto-healing functions

get_mariadb_env_vars() {
  local pod_name="$1"

  log_debug "Setting up credentials for pod $pod_name"

  # Use the deployment environment variables (most reliable)
  export MARIADB_USER="${DB_USER:-root}"
  export MARIADB_PASSWORD="${DB_PASSWORD:-}"

  # Debug output
  log_debug "Using deployment variables - user: $MARIADB_USER, password_length: ${#MARIADB_PASSWORD}"

  if [[ -z "$MARIADB_PASSWORD" ]]; then
    log_debug "MARIADB_PASSWORD is empty"
    return 1
  fi

  return 0
}

# =============================================================================
# GALERA CLUSTER HEALTH AND MONITORING
# =============================================================================

  # Function to check if a Galera pod is ready and synced
check_galera_pod_ready() {
  local pod_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_cluster_size="${3:-}"

  # Auto-detect expected cluster size if not provided
  if [[ -z "$expected_cluster_size" ]]; then
    # Try to get selector from pod labels and derive expected size
    local app_name=$(oc get pod "$pod_name" -n "$namespace" -o jsonpath='{.metadata.labels.app\.kubernetes\.io/name}' 2>/dev/null)
    if [[ -n "$app_name" ]]; then
      expected_cluster_size=$(get_expected_replica_count "app.kubernetes.io/name=$app_name" "$namespace")
      if [[ $? -ne 0 ]]; then
        echo "❌ Error: Failed to determine expected cluster size for pod $pod_name" >&2
        return 1
      fi
    else
      # Fallback to app label
      local app=$(oc get pod "$pod_name" -n "$namespace" -o jsonpath='{.metadata.labels.app}' 2>/dev/null)
      if [[ -n "$app" ]]; then
        expected_cluster_size=$(get_expected_replica_count "app=$app" "$namespace")
        if [[ $? -ne 0 ]]; then
          echo "❌ Error: Failed to determine expected cluster size for pod $pod_name" >&2
          return 1
        fi
      else
        echo "❌ Error: Unable to determine selector for pod $pod_name" >&2
        return 1
      fi
    fi
  fi

  # Check if pod is in Running state
  local pod_phase=$(oc get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$pod_phase" != "Running" ]]; then
    return 1
  fi

  # Get MariaDB credentials
  if ! get_mariadb_env_vars "$pod_name"; then
    log_debug "Failed to retrieve valid credentials"
    return 1
  fi

  # Debug: Show what credentials we're using (without exposing password)
  log_debug "MARIADB_USER='$MARIADB_USER', password_length=${#MARIADB_PASSWORD}"
  if [[ -z "$MARIADB_PASSWORD" ]]; then
    log_debug "No password found for MariaDB authentication"
    return 1
  fi

  # Check Galera cluster status
  local galera_status
  galera_status=$(oc exec -n "$namespace" "$pod_name" -- \
    mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
    -e "SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_cluster_size';" \
    2>/dev/null) || {
    echo "    ❌ Debug: MySQL connection failed for pod $pod_name"
    return 1
  }

  # Parse the status
  local local_state=$(echo "$galera_status" | awk '/wsrep_local_state_comment/ {print $2}')
  local cluster_size=$(echo "$galera_status" | awk '/wsrep_cluster_size/ {print $2}')

  # Check if node is synced and cluster size is correct
  if [[ "$local_state" == "Synced" && "$cluster_size" == "$expected_cluster_size" ]]; then
    return 0
  else
    return 1
  fi
}

# NOTE: get_mariadb_env_vars is defined once at the top of this file.
# It uses deployment env vars (DB_USER, DB_PASSWORD) for MariaDB auth.

# Main function to wait for Galera cluster to be ready and synced
wait_for_galera_sync() {
  local galera_name="$1"
  local max_retries="${2:-30}"
  local wait_time="${3:-10}"
  local expected_pods="${4:-}"

  echo "⏳ Waiting for Galera cluster to sync: $galera_name"

  local namespace="$DEPLOY_NAMESPACE"
  local selector="app.kubernetes.io/name=$galera_name"

  # Auto-detect expected pods if not provided
  if [[ -z "$expected_pods" ]]; then
    expected_pods=$(get_expected_replica_count "$selector" "$namespace")
    if [[ $? -ne 0 ]]; then
      echo "❌ Error: Failed to determine expected pod count" >&2
      return 1
    fi
    echo "  📊 Auto-detected expected pod count: $expected_pods"
  fi

  echo "⏳ Waiting for $galera_name resource to be ready..."

  # First wait for the StatefulSet to be ready (fast check using status fields)
  if ! wait_for_resource_ready "$selector" "$namespace" "$max_retries" "$wait_time" "Galera StatefulSet"; then
    echo "❌ Error: Galera StatefulSet failed to become ready" >&2
    return 1
  fi

  # Now verify Galera-specific health (cluster synchronization)
  echo "✅ StatefulSet ready, now verifying Galera cluster synchronization..."

  # Fail fast if credentials are not available — retrying won't help
  if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "⚠️ DB_PASSWORD not set — cannot verify Galera sync (skipping)"
    echo "  ℹ️ StatefulSet is ready; Galera sync verification requires database credentials"
    return 0
  fi

  local retries=0
  while [[ $retries -lt $max_retries ]]; do
    local pods=( $(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[*].metadata.name}') )
    local pod_count=${#pods[@]}

    if [[ $pod_count -eq $expected_pods ]]; then
      # Check if all pods are Galera-ready
      local healthy_pods=0
      for pod in "${pods[@]}"; do
        if check_galera_pod_ready "$pod" "$namespace" "$expected_pods"; then
          healthy_pods=$((healthy_pods + 1))
        fi
      done

      if [[ $healthy_pods -eq $expected_pods ]]; then
        echo "✅ All $expected_pods Galera pods are healthy and synced"
        return 0
      else
        echo "    $healthy_pods/$expected_pods pods are Galera-ready... (retry $retries/$max_retries)"
      fi
    else
      echo "    Pod count mismatch: found $pod_count, expected $expected_pods (retry $retries/$max_retries)"
    fi

    retries=$((retries + 1))
    sleep $wait_time
  done

  echo "⚠️ Timeout: Galera cluster did not synchronize after $((max_retries * wait_time)) seconds"
  return 1
}

# Enhanced Galera cluster health check with better error handling and logging
check_galera_cluster_health() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-}"

  # Dynamically determine expected size if not provided
  if [[ -z "$expected_size" ]]; then
    expected_size=$(get_expected_replica_count "$selector" "$namespace")
    if [[ $? -ne 0 ]]; then
      echo "❌ Error: Failed to determine expected cluster size" >&2
      return 1
    fi
    echo "  📊 Auto-detected expected cluster size: $expected_size"
  fi

  # Validate database credentials before proceeding — avoids false positives
  if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "  ⚠️ DB_PASSWORD not set — skipping Galera health check (cannot authenticate to MySQL)" >&2
    return 0
  fi

  # Get running pods using the selector
  local pods=( $(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[*].metadata.name}') )

  if [[ ${#pods[@]} -eq 0 ]]; then
    echo "  ℹ️ No running Galera pods found for selector: $selector"
    return 0
  fi

  # Verify running pods match expected count
  if [[ ${#pods[@]} -eq $expected_size ]]; then
    echo "  ✅ All $expected_size Galera pod(s) are running"
  else
    echo "  ⚠️ Pod count mismatch: ${#pods[@]} running, $expected_size expected"
  fi

  echo "  🩺 Checking Galera cluster health for ${#pods[@]} pods..."

  local healthy_pods=0
  local uuids=()
  local sizes=()
  local states=()
  local detailed_status=""

  # Check each pod using existing utility function
  for pod in "${pods[@]}"; do
    if check_galera_pod_ready "$pod" "$namespace" "$expected_size"; then
      healthy_pods=$((healthy_pods + 1))
      echo "    ✅ $pod: healthy and synced"
    else
      echo "    ❌ $pod: unhealthy or not synced"
    fi

    # Get detailed status for split-brain detection
    local status_output
    get_mariadb_env_vars "$pod"
    status_output=$(oc exec -n "$namespace" "$pod" -- \
      mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
      -e "SHOW STATUS LIKE 'wsrep_cluster_state_uuid'; SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_local_state_comment';" \
      2>/dev/null) || continue

    local uuid=$(echo "$status_output" | awk '/wsrep_cluster_state_uuid/ {print $2}')
    local size=$(echo "$status_output" | awk '/wsrep_cluster_size/ {print $2}')
    local state=$(echo "$status_output" | awk '/wsrep_local_state_comment/ {print $2}')

    uuids+=("$uuid")
    sizes+=("$size")
    states+=("$state")
    detailed_status+="$pod: uuid=$uuid, size=$size, state=$state; "
  done

  # Analyze cluster consistency
  local unique_uuids=$(printf "%s\n" "${uuids[@]}" | sort | uniq | grep -v '^$' | wc -l)
  local unique_sizes=$(printf "%s\n" "${sizes[@]}" | sort | uniq | grep -v '^$' | wc -l)

  # Check for split-brain or inconsistency
  if [[ $unique_uuids -gt 1 || $unique_sizes -gt 1 ]]; then
    send_notification "GALERA_SPLIT_BRAIN_DETECTED" "🚨 Galera Split-Brain Detected!" "Split-brain detected! UUIDs: $unique_uuids, Sizes: $unique_sizes. Details: $detailed_status" "error" "$namespace"
    return 2  # Split-brain detected
  elif [[ $healthy_pods -lt $expected_size ]]; then
    send_notification "GALERA_UNHEALTHY_PODS" "Galera Pods Unhealthy" "Some pods unhealthy: $healthy_pods/$expected_size healthy. Details: $detailed_status" "warning" "$namespace"
    return 1  # Some pods unhealthy
  else
    echo "    ✅ Galera cluster healthy: all $healthy_pods pods synced and consistent"
    return 0  # All healthy
  fi
}

# Function to auto-heal Galera cluster using existing utilities
auto_heal_galera_cluster() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  send_notification "GALERA_AUTO_HEAL_START" "🔧 Galera Auto-Heal Starting" "Initiating Galera auto-heal for selector: $selector" "healing" "$namespace"

  # Extract resource name from selector (e.g., "app.kubernetes.io/name=mariadb-galera" -> "mariadb-galera")
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Determine resource type and current replicas
  local resource_type=""
  local original_replicas=""

  if oc get statefulset "$resource_name" -n "$namespace" &> /dev/null; then
    resource_type="statefulset"
    original_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}')
  elif oc get deployment "$resource_name" -n "$namespace" &> /dev/null; then
    resource_type="deployment"
    original_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}')
  else
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - No Resource" "Could not find StatefulSet or Deployment for selector: $selector (resource: $resource_name)" "error" "$namespace"
    return 1
  fi

  if [[ -z "$original_replicas" || "$original_replicas" == "0" ]]; then
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - Invalid Replicas" "Could not determine valid replica count for $resource_type: $resource_name" "error" "$namespace"
    return 1
  fi

  # Single-replica cluster — scaling 1→1→1 is a no-op, try pod restart instead
  if [[ "$original_replicas" == "1" ]]; then
    echo "  ℹ️ Single-replica cluster — attempting pod restart instead of scale cycle"
    local pod_name
    pod_name=$(oc get pods -l "$selector" -n "$namespace" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$pod_name" ]]; then
      echo "  🔄 Deleting pod $pod_name to trigger recreation..."
      oc delete pod "$pod_name" -n "$namespace" --grace-period=30
      echo "  ⏳ Waiting for pod to recreate..."
      if scale_simple "$resource_type" "$resource_name" "1" "$namespace" "300s"; then
        send_notification "GALERA_AUTO_HEAL_SUCCESS" "✅ Single-Replica Pod Restarted" "Restarted pod $pod_name for $resource_type/$resource_name" "success" "$namespace"
        return 0
      else
        send_notification "GALERA_AUTO_HEAL_FAILED" "Pod Restart Failed" "Failed to restart $resource_type/$resource_name after pod deletion" "error" "$namespace"
        return 1
      fi
    else
      echo "  ⚠️ No running pod found to restart"
      return 1
    fi
  fi

  send_notification "GALERA_AUTO_HEAL_SCALING" "🔄 Starting Auto-Heal Process" "Auto-healing $resource_type/$resource_name: $original_replicas → 1 → $original_replicas replicas" "healing" "$namespace"

  # Step 1: Scale down to 1 replica (keeps one node as primary)
  echo "🔽 Step 1: Scaling down to 1 replica to establish primary node..."
  if ! scale_simple "$resource_type" "$resource_name" "1" "$namespace" "300s"; then
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - Scale to 1" "Failed to scale $resource_type/$resource_name to 1 replica" "error" "$namespace"
    return 1
  fi

  # Wait a bit for the remaining node to stabilize
  echo "⏸️  Waiting 30 seconds for primary node to stabilize..."
  sleep 30

  # Step 2: Scale back up to original replica count
  echo "🔼 Step 2: Scaling back up to $original_replicas replicas..."
  if ! scale_simple "$resource_type" "$resource_name" "$original_replicas" "$namespace" "600s"; then
    send_notification "GALERA_AUTO_HEAL_PARTIAL" "Auto-Heal Partial - Scale Up Failed" "Scaled to 1 but failed to scale back to $original_replicas replicas" "warning" "$namespace"
    return 1
  fi

  # Step 3: Wait for Galera cluster to sync using enhanced utility
  echo "🔄 Step 3: Waiting for Galera cluster synchronization..."
  if wait_for_galera_sync "$resource_name" 60 15 "$original_replicas"; then
    send_notification "GALERA_AUTO_HEAL_SUCCESS" "✅ Auto-Heal Successful" "Successfully auto-healed $resource_type/$resource_name: all $original_replicas replicas are healthy and synced" "success" "$namespace"
    return 0
  else
    send_notification "GALERA_AUTO_HEAL_PARTIAL" "⚠️ Auto-Heal Partial Success" "$resource_type/$resource_name scaled successfully but Galera sync verification failed" "warning" "$namespace"
    return 1
  fi
}

# Combined function for health check and auto-heal
check_and_heal_galera_cluster() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-}"
  local auto_heal="${4:-true}"

  # Dynamically determine expected size if not provided
  if [[ -z "$expected_size" ]]; then
    expected_size=$(get_expected_replica_count "$selector" "$namespace")
    if [[ $? -ne 0 ]]; then
      echo "❌ Error: Failed to determine expected cluster size" >&2
      return 1
    fi
    echo "  📊 Auto-detected expected cluster size: $expected_size"
  fi

  # Run health check directly — do NOT capture stdout or diagnostics are invisible
  check_galera_cluster_health "$selector" "$namespace" "$expected_size"
  local health_code=$?

  case $health_code in
    0)
      echo "✅ Galera cluster is healthy - no action needed"
      return 0
      ;;
    1)
      echo "⚠️ Some Galera pods are unhealthy"
      if [[ "$auto_heal" == "true" ]]; then
        echo "🔧 Attempting auto-heal..."
        auto_heal_galera_cluster "$selector" "$namespace"
      fi
      ;;
    2)
      echo "🚨 Split-brain detected in Galera cluster"
      if [[ "$auto_heal" == "true" ]]; then
        echo "🔧 Attempting auto-heal for split-brain..."
        auto_heal_galera_cluster "$selector" "$namespace"
      fi
      ;;
    *)
      echo "❌ Unknown health check result"
      return 1
      ;;
  esac
}

# =============================================================================
# DATABASE CONTENT MANAGEMENT
# =============================================================================

# Function to find problematic database characters
find_db_characters() {
  local pod_name="$1"
  local database_name="${2:-moodle}"
  local output_file="${3:-/tmp/db_characters.csv}"

  echo "🔍 Finding problematic characters in database: $database_name"

  get_mariadb_env_vars "$pod_name"

  # Execute character finding query
  local query="SELECT CONCAT(TABLE_SCHEMA, '.', TABLE_NAME, '.', COLUMN_NAME) as location,
                     COUNT(*) as count
              FROM INFORMATION_SCHEMA.COLUMNS c
              JOIN $database_name.* t ON 1=1
              WHERE c.TABLE_SCHEMA = '$database_name'
              AND c.DATA_TYPE IN ('text', 'longtext', 'mediumtext', 'varchar')
              AND t.[COLUMN_NAME] REGEXP '[^\x00-\x7F]'
              GROUP BY location
              ORDER BY count DESC;"

  oc exec -n "$DEPLOY_NAMESPACE" "$pod_name" -- \
    mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "$query" > "$output_file"

  echo "✅ Character analysis saved to: $output_file"
}

# Function to replace problematic characters from CSV
replace_db_characters_from_csv() {
  local pod_name="$1"
  local csv_file="$2"
  local database_name="${3:-moodle}"

  echo "🔧 Replacing problematic characters based on CSV: $csv_file"

  get_mariadb_env_vars "$pod_name"

  # Process CSV and create replacement queries
  while IFS=',' read -r location count; do
    if [[ "$location" != "location" ]]; then  # Skip header
      local table_column="${location#*.}"  # Remove database name
      local table_name="${table_column%.*}"
      local column_name="${table_column#*.}"

      echo "  Fixing $count characters in $table_name.$column_name"

      local update_query="UPDATE $database_name.$table_name
                         SET $column_name = REPLACE(REPLACE($column_name, CHAR(160), ' '), CHAR(194), '')
                         WHERE $column_name REGEXP '[^\x00-\x7F]';"

      oc exec -n "$DEPLOY_NAMESPACE" "$pod_name" -- \
        mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "$update_query"
    fi
  done < "$csv_file"

  echo "✅ Character replacement completed"
}


# Function to process Moodle content columns
process_moodle_content_columns() {
  local pod_name="$1"
  local operation="${2:-clean}"  # clean, analyze, or fix

  echo "🔧 Processing Moodle content columns: $operation"

  case "$operation" in
    "analyze")
      find_db_characters "$pod_name" "moodle" "/tmp/moodle_characters.csv"
      ;;
    "clean"|"fix")
      if [[ -f "/tmp/moodle_characters.csv" ]]; then
        replace_db_characters_from_csv "$pod_name" "/tmp/moodle_characters.csv" "moodle"
      else
        echo "⚠️ Character analysis file not found. Running analysis first..."
        find_db_characters "$pod_name" "moodle" "/tmp/moodle_characters.csv"
        replace_db_characters_from_csv "$pod_name" "/tmp/moodle_characters.csv" "moodle"
      fi
      ;;
    *)
      echo "❌ Unknown operation: $operation. Use: analyze, clean, or fix"
      return 1
      ;;
  esac
}

# Function for Moodle content cleanup
moodle_content_cleanup() {
  local pod_name="$1"
  local cleanup_type="${2:-full}"  # full, analyze, or fix

  echo "🧹 Moodle content cleanup: $cleanup_type"
  process_moodle_content_columns "$pod_name" "$cleanup_type"
}

# =============================================================================
# MIGRATION AND VERSION MANAGEMENT
# =============================================================================

# Function to check if migration should run based on version
should_migrate_by_version() {
  local current_version="$1"
  local target_version="$2"
  local migration_type="${3:-major}"  # major, minor, or patch

  echo "🔍 Checking migration requirement: $current_version → $target_version"

  # Parse version numbers
  IFS='.' read -ra current <<< "$current_version"
  IFS='.' read -ra target <<< "$target_version"

  local current_major=${current[0]:-0}
  local current_minor=${current[1]:-0}
  local current_patch=${current[2]:-0}

  local target_major=${target[0]:-0}
  local target_minor=${target[1]:-0}
  local target_patch=${target[2]:-0}

  case "$migration_type" in
    "major")
      if [[ $target_major -gt $current_major ]]; then
        echo "✅ Major version migration required"
        return 0
      fi
      ;;
    "minor")
      if [[ $target_major -gt $current_major ]] || [[ $target_major -eq $current_major && $target_minor -gt $current_minor ]]; then
        echo "✅ Minor version migration required"
        return 0
      fi
      ;;
    "patch")
      if [[ $target_major -gt $current_major ]] || [[ $target_major -eq $current_major && $target_minor -gt $current_minor ]] || [[ $target_major -eq $current_major && $target_minor -eq $current_minor && $target_patch -gt $current_patch ]]; then
        echo "✅ Patch version migration required"
        return 0
      fi
      ;;
  esac

  # Provide more specific messaging based on version comparison
  if [[ "$current_version" == "$target_version" ]]; then
    echo "ℹ️ Versions are identical ($current_version) - no migration needed"
    return 1
  else
    # Check if this is a downgrade scenario (dangerous!)
    local is_downgrade=false

    if [[ $target_major -lt $current_major ]]; then
      is_downgrade=true
    elif [[ $target_major -eq $current_major && $target_minor -lt $current_minor ]]; then
      is_downgrade=true
    elif [[ $target_major -eq $current_major && $target_minor -eq $current_minor && $target_patch -lt $current_patch ]]; then
      is_downgrade=true
    fi

    if [[ "$is_downgrade" == "true" ]]; then
      echo "🚨 CRITICAL: Downgrade detected! Target version ($target_version) is older than current ($current_version)"
      echo "❌ Database downgrade is dangerous and could cause data corruption or loss"
      echo "❌ Deployment aborted to protect database integrity"
      return 2  # Error code 2 indicates dangerous downgrade
    else
      # This shouldn't happen given our logic above, but just in case
      echo "ℹ️ Target version ($target_version) is not newer than current ($current_version) - no $migration_type migration needed"
      return 1
    fi
  fi
}

# Function to manage backup storage secrets with environment-specific values
# This function is now a thin wrapper around manage_secret_with_validation for backward compatibility
# and to provide a convenient interface for backup storage secrets
# Return codes:
#   0 - Secret already exists with correct values (no changes made)
#   2 - Secret was created or updated successfully (changes made - restart may be needed)
#   1 - Error occurred
# Usage examples:
#   - Basic backup storage secret management:
#     manage_backup_storage_secrets "$namespace" "secret-name" "key1=value1,key2=value2"
#   - With validation feedback:
#     manage_backup_storage_secrets "$namespace" "secret-name" "key1=value1,key2=value2" "key1,key2" "my secrets"
#   - For other secrets, use manage_secret_with_validation directly
manage_backup_storage_secrets() {
  local namespace="${1:-$DEPLOY_NAMESPACE}"
  local secret_name="${2:-moodle-db-backup-storage-secrets}"
  local secret_values="${3}"  # Format: "key1=value1,key2=value2"
  local validation_keys="${4:-}"  # Optional: specific keys to validate and provide feedback for
  local secret_description="${5:-backup storage secrets}"

  # Use the generic function with provided parameters and propagate return code
  manage_secret_with_validation "$secret_name" "$secret_values" "$namespace" "$validation_keys" "$secret_description"
}
