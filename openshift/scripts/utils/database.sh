#!/bin/bash

# Database Utilities Module
# Contains Galera/MariaDB operations, health checks, and auto-healing functions

# =============================================================================
# GALERA CLUSTER HEALTH AND MONITORING
# =============================================================================

# Enhanced Galera cluster health check with better error handling and logging
check_galera_cluster_health() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-5}"

  send_notification "GALERA_HEALTH_CHECK_START" "Galera Health Check Starting" "Checking cluster health for selector: $selector" "info" "$namespace"

  # Get running pods using the selector
  local pods=( $(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[*].metadata.name}') )

  if [[ ${#pods[@]} -eq 0 ]]; then
    send_notification "GALERA_NO_PODS" "No Galera Pods Found" "No running Galera pods found for selector: $selector" "error" "$namespace"
    return 0
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

# Enhanced Galera sync function that works with selectors
wait_for_galera_cluster_sync() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-5}"
  local max_retries="${4:-30}"
  local wait_time="${5:-10}"

  echo "⏳ Waiting for Galera cluster to sync (selector: $selector, expected size: $expected_size)..."

  local retries=0
  while [[ $retries -lt $max_retries ]]; do
    # Get running pods using selector
    local pods=( $(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[*].metadata.name}') )
    local pod_count=${#pods[@]}

    if [[ $pod_count -eq 0 ]]; then
      echo "    No running pods found yet... (retry $retries/$max_retries)"
      retries=$((retries + 1))
      sleep $wait_time
      continue
    fi

    if [[ $pod_count -lt $expected_size ]]; then
      echo "    $pod_count/$expected_size pods running, waiting for more... (retry $retries/$max_retries)"
      retries=$((retries + 1))
      sleep $wait_time
      continue
    fi

    # Check if all pods are Galera-ready
    local healthy_pods=0
    for pod in "${pods[@]}"; do
      if check_galera_pod_ready "$pod" "$namespace" "$expected_size"; then
        healthy_pods=$((healthy_pods + 1))
      fi
    done

    if [[ $healthy_pods -eq $expected_size ]]; then
      echo "✅ All $expected_size Galera pods are healthy and synced"
      return 0
    else
      echo "    $healthy_pods/$expected_size pods are Galera-ready... (retry $retries/$max_retries)"
    fi

    retries=$((retries + 1))
    sleep $wait_time
  done

  echo "⚠️ Timeout: Only $healthy_pods/$expected_size pods became Galera-ready after $((max_retries * wait_time)) seconds"
  return 1
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

  # Use existing function to determine resource type and get current replicas
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
  if wait_for_galera_cluster_sync "$selector" "$namespace" "$original_replicas" 60 15; then
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
  local expected_size="${3:-5}"
  local auto_heal="${4:-true}"

  local health_status
  health_status=$(check_galera_cluster_health "$selector" "$namespace" "$expected_size")
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
# GALERA POD MANAGEMENT
# =============================================================================

# Function to check if a Galera pod is ready and synced
check_galera_pod_ready() {
  local pod_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_cluster_size="${3:-5}"

  # Check if pod is in Running state
  local pod_phase=$(oc get pod "$pod_name" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$pod_phase" != "Running" ]]; then
    return 1
  fi

  # Get MariaDB credentials
  get_mariadb_env_vars "$pod_name"

  # Check Galera cluster status
  local galera_status
  galera_status=$(oc exec -n "$namespace" "$pod_name" -- \
    mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
    -e "SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_cluster_size';" \
    2>/dev/null) || return 1

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

# Function to get MariaDB environment variables for a pod
get_mariadb_env_vars() {
  local pod_name="$1"

  # Set default values that will be used by other functions
  export MARIADB_USER="${MARIADB_USER:-root}"
  export MARIADB_PASSWORD="${MARIADB_PASSWORD:-}"

  # Try to get password from pod environment if not set
  if [[ -z "$MARIADB_PASSWORD" ]]; then
    MARIADB_PASSWORD=$(oc get pod "$pod_name" -o jsonpath='{.spec.containers[0].env[?(@.name=="MARIADB_ROOT_PASSWORD")].value}' 2>/dev/null || echo "")
    export MARIADB_PASSWORD
  fi

  # Try to get from secret if still empty
  if [[ -z "$MARIADB_PASSWORD" ]]; then
    local secret_name=$(oc get pod "$pod_name" -o jsonpath='{.spec.containers[0].env[?(@.name=="MARIADB_ROOT_PASSWORD")].valueFrom.secretKeyRef.name}' 2>/dev/null)
    local secret_key=$(oc get pod "$pod_name" -o jsonpath='{.spec.containers[0].env[?(@.name=="MARIADB_ROOT_PASSWORD")].valueFrom.secretKeyRef.key}' 2>/dev/null)

    if [[ -n "$secret_name" && -n "$secret_key" ]]; then
      MARIADB_PASSWORD=$(get_secret_value "$secret_name" "$secret_key")
      export MARIADB_PASSWORD
    fi
  fi
}

# Legacy function for backward compatibility
wait_for_galera_sync() {
  local galera_name="$1"
  local max_retries="${2:-30}"
  local wait_time="${3:-10}"
  local expected_pods="${4:-5}"

  echo "⏳ Waiting for Galera sync (legacy function): $galera_name"

  # Convert to selector format and use new function
  local selector="app.kubernetes.io/name=$galera_name"
  wait_for_galera_cluster_sync "$selector" "$DEPLOY_NAMESPACE" "$expected_pods" "$max_retries" "$wait_time"
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

# Function to read CSV file content
read_csv_file() {
  local csv_file="$1"

  if [[ -f "$csv_file" ]]; then
    cat "$csv_file"
  else
    echo "❌ CSV file not found: $csv_file"
    return 1
  fi
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

  echo "ℹ️ No migration required for $migration_type version change"
  return 1
}