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

# Function to auto-heal Galera cluster using galera_safe_upgrade()
# Delegates to the shared upgrade function for consistent behavior
# across deploy scripts and health monitoring.
auto_heal_galera_cluster() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  send_notification "GALERA_AUTO_HEAL_START" "Galera Auto-Heal Starting" "Initiating Galera auto-heal for selector: $selector" "healing" "$namespace"

  # Extract resource name from selector (e.g., "app.kubernetes.io/name=mariadb-galera" -> "mariadb-galera")
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Verify this is a StatefulSet (Galera runs as StatefulSet)
  if ! oc get statefulset "$resource_name" -n "$namespace" &>/dev/null; then
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - No StatefulSet" "Could not find StatefulSet: $resource_name" "error" "$namespace"
    return 1
  fi

  local original_replicas
  original_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}')

  if [[ -z "$original_replicas" || "$original_replicas" == "0" ]]; then
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - Invalid Replicas" "Could not determine valid replica count for statefulset: $resource_name" "error" "$namespace"
    return 1
  fi

  send_notification "GALERA_AUTO_HEAL_SCALING" "Starting Auto-Heal Process" "Auto-healing statefulset/$resource_name: safe upgrade cycle to $original_replicas replicas" "healing" "$namespace"

  # Delegate to galera_safe_upgrade for the actual work
  if galera_safe_upgrade "$resource_name" "$original_replicas" "$namespace"; then
    send_notification "GALERA_AUTO_HEAL_SUCCESS" "Auto-Heal Successful" "Successfully auto-healed statefulset/$resource_name: all $original_replicas replicas are healthy and synced" "success" "$namespace"
    return 0
  else
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed" "galera_safe_upgrade failed for statefulset/$resource_name -- manual intervention required" "error" "$namespace"
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
      echo "Unknown health check result"
      return 1
      ;;
  esac
}

# =============================================================================
# GALERA SAFE UPGRADE -- shared upgrade/recovery orchestration
# =============================================================================
# These functions are used by BOTH the deploy script (via Helm) and the
# health monitor (via oc commands) to ensure consistent, safe Galera
# cluster operations.
#
# Key principle: galera-0's PVC (data-mariadb-galera-0) is ALWAYS preserved.
# Secondary PVCs are expendable -- secondaries rebuild via SST from primary.
# =============================================================================

# Verify galera-0 is safe to bootstrap from.
# Checks wsrep state to confirm galera-0 has authoritative data.
#
# Arguments:
#   $1 - StatefulSet name (e.g., mariadb-galera)
#   $2 - Namespace (optional, defaults to DEPLOY_NAMESPACE)
#
# Returns:
#   0 = galera-0 is safe to bootstrap (Synced, or no pods running)
#   1 = galera-0 is NOT safe (unhealthy, not synced, or split-brain)
galera_verify_bootstrap_safe() {
  local sts_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  echo "Verifying galera-0 is safe to bootstrap from..."

  # Check if any pods are running
  local running_pods
  running_pods=$(oc get pods -l "app.kubernetes.io/name=$sts_name" \
    --field-selector=status.phase=Running -n "$namespace" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

  if [[ -z "$running_pods" ]]; then
    echo "   No running Galera pods -- will bootstrap from galera-0 PVC data"
    # Check if galera-0 PVC exists
    if oc get pvc "data-${sts_name}-0" -n "$namespace" &>/dev/null; then
      echo "   PVC data-${sts_name}-0 exists -- bootstrap will use existing data"
      return 0
    else
      echo "   No PVC found -- fresh cluster (empty bootstrap)"
      return 0
    fi
  fi

  # If credentials aren't available, we can't check wsrep state
  if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "   DB_PASSWORD not set -- cannot verify Galera state (proceeding cautiously)"
    return 0
  fi

  # Check galera-0 specifically
  local pod_0="${sts_name}-0"
  local pod_0_phase
  pod_0_phase=$(oc get pod "$pod_0" -n "$namespace" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  if [[ "$pod_0_phase" != "Running" ]]; then
    echo "   galera-0 is not Running (phase: ${pod_0_phase:-NotFound})"
    echo "   Other pods may have more recent data -- manual review needed"
    echo ""
    echo "   To identify the most recent node:"
    echo "   for pod in $running_pods; do"
    echo "     oc exec \$pod -n $namespace -- cat /bitnami/mariadb/data/grastate.dat"
    echo "   done"
    echo "   The node with the highest seqno has the most recent data."
    return 1
  fi

  # Query galera-0 wsrep state
  get_mariadb_env_vars "$pod_0"
  local status_output
  status_output=$(oc exec -n "$namespace" "$pod_0" -- \
    mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
    -e "SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_cluster_state_uuid'; SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_last_committed';" \
    2>/dev/null) || {
    echo "   Could not connect to MariaDB on galera-0"
    echo "   Pod may be starting up or in crash loop -- check pod logs"
    return 1
  }

  local state=$(echo "$status_output" | awk '/wsrep_local_state_comment/ {print $2}')
  local uuid=$(echo "$status_output" | awk '/wsrep_cluster_state_uuid/ {print $2}')
  local size=$(echo "$status_output" | awk '/wsrep_cluster_size/ {print $2}')
  local seqno=$(echo "$status_output" | awk '/wsrep_last_committed/ {print $2}')

  echo "   galera-0 state: $state, uuid: $uuid, cluster_size: $size, seqno: $seqno"

  if [[ "$state" != "Synced" ]]; then
    echo "   galera-0 is NOT Synced (state: $state)"
    echo "   Cannot safely bootstrap from a non-synced node"
    return 1
  fi

  # Check for split-brain: if cluster_size < expected, other pods may have diverged
  local expected_replicas
  expected_replicas=$(oc get sts/"$sts_name" -n "$namespace" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ "$size" -lt "$expected_replicas" && "$expected_replicas" -gt 1 ]]; then
    echo "   Galera cluster_size ($size) < expected replicas ($expected_replicas)"
    echo "   Some pods may not be part of the cluster -- checking for split-brain..."

    # Get UUIDs from all running pods
    local uuids=("$uuid")
    for pod in $running_pods; do
      [[ "$pod" == "$pod_0" ]] && continue
      local pod_uuid
      pod_uuid=$(oc exec -n "$namespace" "$pod" -- \
        mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
        -e "SHOW STATUS LIKE 'wsrep_cluster_state_uuid';" 2>/dev/null \
        | awk '/wsrep_cluster_state_uuid/ {print $2}') || continue
      if [[ -n "$pod_uuid" ]]; then
        uuids+=("$pod_uuid")
      fi
    done

    local unique_uuids=$(printf "%s\n" "${uuids[@]}" | sort -u | wc -l)
    if [[ "$unique_uuids" -gt 1 ]]; then
      echo ""
      echo "   SPLIT-BRAIN DETECTED: $unique_uuids different cluster UUIDs"
      echo "   UUIDs found: $(printf '%s\n' "${uuids[@]}" | sort -u | tr '\n' ' ')"
      echo ""
      echo "   galera-0 has uuid=$uuid seqno=$seqno"
      echo "   Secondary PVCs will be deleted -- galera-0 data will be authoritative"
      echo "   Verify galera-0 has production data after recovery."
      # Still return 0 -- galera-0 is Synced (in its own cluster), and we'll
      # delete secondary PVCs to resolve the split-brain
      return 0
    fi
  fi

  echo "   galera-0 is Synced and safe to bootstrap from"
  return 0
}

# Delete all secondary PVCs for a Galera StatefulSet.
# Preserves data-${sts_name}-0 (the primary's data).
#
# Arguments:
#   $1 - StatefulSet name
#   $2 - Target replica count (deletes PVCs 1..N-1)
#   $3 - Namespace (optional)
#
# Returns:
#   0 = success (all secondary PVCs deleted or not found)
#   1 = error (PVC stuck in Terminating, etc.)
galera_delete_secondary_pvcs() {
  local sts_name="$1"
  local target_replicas="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  if [[ "$target_replicas" -le 1 ]]; then
    echo "   Single-replica cluster -- no secondary PVCs to delete"
    return 0
  fi

  echo "Deleting secondary PVCs (preserving data-${sts_name}-0)..."
  local failed=0
  for i in $(seq 1 $((target_replicas - 1))); do
    local pvc_name="data-${sts_name}-${i}"
    if oc get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
      echo "   Deleting PVC: $pvc_name"
      if ! oc delete pvc "$pvc_name" -n "$namespace" --wait=true --timeout=120s 2>/dev/null; then
        echo "   Warning: PVC $pvc_name did not delete within 120s"
        failed=1
      fi
    else
      echo "   PVC not found (OK): $pvc_name"
    fi
  done

  # Also delete any orphaned PVCs beyond the target count
  local existing_pvcs
  existing_pvcs=$(oc get pvc -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
  for pvc in $existing_pvcs; do
    if [[ "$pvc" =~ ^data-${sts_name}-([0-9]+)$ ]]; then
      local idx="${BASH_REMATCH[1]}"
      if [[ "$idx" -ge "$target_replicas" ]]; then
        echo "   Deleting orphaned PVC: $pvc (index $idx >= target $target_replicas)"
        oc delete pvc "$pvc" -n "$namespace" --wait=true --timeout=120s 2>/dev/null || true
      fi
    fi
  done

  return $failed
}

# Full safe upgrade/recovery cycle for Galera cluster using oc commands.
# Used by auto_heal_galera_cluster() and can be called directly by
# scripts that don't use Helm (e.g., health monitor).
#
# For Helm-based deployments (deploy-mariadb-galera.sh), use:
#   galera_verify_bootstrap_safe() + galera_delete_secondary_pvcs()
#   with Helm upgrade commands for the actual bootstrap/scale steps.
#
# Sequence:
#   1. Pre-check: verify galera-0 is safe
#   2. Scale to 0 (OrderedReady = galera-0 shuts down last)
#   3. Delete secondary PVCs
#   4. Set bootstrap env vars on StatefulSet template
#   5. Scale to 1 (galera-0 bootstraps from its PVC)
#   6. Wait for galera-0 Ready
#   7. Clear bootstrap env vars
#   8. Scale to target_replicas (OrderedReady = sequential)
#   9. Wait for sync + health check
#
# Arguments:
#   $1 - StatefulSet name
#   $2 - Target replica count
#   $3 - Namespace (optional)
#
# Returns:
#   0 = success
#   1 = failure (check logs for details)
galera_safe_upgrade() {
  local sts_name="$1"
  local target_replicas="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local selector="app.kubernetes.io/name=$sts_name"

  echo ""
  echo "======================================================================="
  echo "GALERA SAFE UPGRADE: $sts_name -> $target_replicas replicas"
  echo "======================================================================="

  # Step 1: Pre-check
  echo "Step 1: Pre-flight verification..."
  if ! galera_verify_bootstrap_safe "$sts_name" "$namespace"; then
    echo "ABORT: galera-0 is not safe to bootstrap from"
    echo "   Manual intervention required before automated upgrade can proceed."
    return 1
  fi

  # Step 2: Scale to 0
  echo ""
  echo "Step 2: Scaling $sts_name to 0 replicas..."
  oc scale sts/"$sts_name" --replicas=0 -n "$namespace"

  # Wait for all pods to terminate
  local wait_count=0
  while [[ $wait_count -lt 180 ]]; do
    local current_pods
    current_pods=$(oc get pods -l "$selector" -n "$namespace" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    if [[ -z "$current_pods" ]]; then
      echo "   All pods terminated"
      break
    fi
    sleep 5
    wait_count=$((wait_count + 5))
    if [[ $((wait_count % 30)) -eq 0 ]]; then
      echo "   Still waiting... ${wait_count}s elapsed (pods: $current_pods)"
    fi
  done
  if [[ $wait_count -ge 180 ]]; then
    echo "   Warning: pods did not terminate within 180s"
  fi

  # Step 3: Delete secondary PVCs
  echo ""
  echo "Step 3: Deleting secondary PVCs..."
  galera_delete_secondary_pvcs "$sts_name" "$target_replicas" "$namespace"

  # Step 4: Enable bootstrap on galera-0
  echo ""
  echo "Step 4: Enabling bootstrap mode on StatefulSet template..."
  oc set env statefulset/"$sts_name" \
    "MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes" \
    "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes" \
    -n "$namespace"

  # Step 5: Scale to 1 (galera-0 bootstraps)
  echo ""
  echo "Step 5: Scaling to 1 replica (galera-0 bootstrap)..."
  oc scale sts/"$sts_name" --replicas=1 -n "$namespace"

  # Step 6: Wait for galera-0 Ready
  echo "Waiting for ${sts_name}-0 to bootstrap and become Ready..."
  local ready_wait=0
  while [[ $ready_wait -lt 600 ]]; do
    local pod_ready
    pod_ready=$(oc get pod "${sts_name}-0" -n "$namespace" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
    if [[ "$pod_ready" == "True" ]]; then
      echo "   ${sts_name}-0 is Ready (bootstrapped as primary)"
      break
    fi
    sleep 10
    ready_wait=$((ready_wait + 10))
    if [[ $((ready_wait % 60)) -eq 0 ]]; then
      echo "   Still waiting... ${ready_wait}s elapsed"
    fi
  done
  if [[ $ready_wait -ge 600 ]]; then
    echo "   ${sts_name}-0 failed to bootstrap within 600s"
    # Restore safe state before returning failure
    oc set env statefulset/"$sts_name" \
      "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
      "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
      -n "$namespace" 2>/dev/null || true
    return 1
  fi

  # Step 7: Disable bootstrap (so secondaries join, not bootstrap)
  echo ""
  echo "Step 7: Disabling bootstrap mode..."
  oc set env statefulset/"$sts_name" \
    "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
    "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
    -n "$namespace"

  # Step 8: Scale to target (if > 1)
  if [[ "$target_replicas" -gt 1 ]]; then
    echo ""
    echo "Step 8: Scaling to $target_replicas replicas..."
    oc scale sts/"$sts_name" --replicas="$target_replicas" -n "$namespace"

    # Step 9: Wait for sync
    echo ""
    echo "Step 9: Waiting for Galera cluster synchronization..."
    if ! wait_for_galera_sync "$sts_name" 60 10 "$target_replicas"; then
      echo "   Galera sync verification failed -- check pod logs"
      return 1
    fi

    # Verify no split-brain
    check_galera_cluster_health "$selector" "$namespace" "$target_replicas"
    local health=$?
    if [[ $health -ne 0 ]]; then
      echo "   Post-upgrade health check failed (code: $health)"
      return 1
    fi
  else
    echo ""
    echo "Single-replica cluster -- skipping sync verification"
  fi

  echo ""
  echo "Galera safe upgrade completed successfully"
  echo "======================================================================="
  return 0
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

# Detect breaking changes between two container image references.
# Compares repository path and major version to determine safety level.
# Uses should_migrate_by_version() for semver parsing (DRY).
#
# Arguments:
#   $1 - Live image   (e.g., artifacts.example.com/bitnamilegacy/mariadb-galera:10.6.20)
#   $2 - Desired image (e.g., artifacts.example.com/bitnamilegacy/mariadb-galera:11.0)
#   $3 - (optional) "yes" to allow major upgrades (bypass abort)
#
# Returns:
#   0 = compatible (same repo, same or minor version change)
#   1 = minor version change detected (safe for rolling update)
#   2 = major version change (requires manual intervention)
#   3 = repository/image name change (different product entirely)
#   4 = downgrade detected (dangerous — should never auto-proceed)
detect_breaking_image_change() {
  local live_image="$1"
  local desired_image="$2"
  local allow_major="${3:-no}"

  # Strip registry prefix for repository comparison
  # e.g., "artifacts.example.com/bitnamilegacy/mariadb-galera:10.6" → "bitnamilegacy/mariadb-galera:10.6"
  local live_path="${live_image#*/}"    # strip first path segment (registry)
  local desired_path="${desired_image#*/}"

  # Separate repository and tag
  local live_repo="${live_path%:*}"
  local live_tag="${live_path##*:}"
  local desired_repo="${desired_path%:*}"
  local desired_tag="${desired_path##*:}"

  echo "🔍 Image change analysis:"
  echo "   Live:    $live_image"
  echo "   Desired: $desired_image"

  # Check 1: Repository/product change (e.g., bitnamilegacy/mariadb-galera → bitnami/mariadb)
  if [[ "$live_repo" != "$desired_repo" ]]; then
    echo ""
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    echo "🚨 BREAKING CHANGE: Image repository changed"
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    echo "   Live repository:    $live_repo"
    echo "   Desired repository: $desired_repo"
    echo ""
    echo "   This indicates a fundamentally different image (e.g., vendor change,"
    echo "   product rename, or architecture migration). Automated deployment"
    echo "   cannot safely handle this."
    echo ""
    echo "   📋 Manual steps required:"
    echo "   1. Review the new image's compatibility with existing PVCs and data"
    echo "   2. Back up all Galera PVCs (data-${DB_DEPLOYMENT_NAME:-mariadb-galera}-*)"
    echo "   3. Test the migration in a non-production environment first"
    echo "   4. If compatible, set ALLOW_MAJOR_DB_UPGRADE=yes and re-run"
    echo "   5. If not compatible, plan a full data migration"
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    return 3
  fi

  # Check 2: Version comparison using existing should_migrate_by_version()
  # Extract comparable version from tags (strip non-numeric suffixes like "-debian-12")
  local live_ver=$(echo "$live_tag" | grep -oP '^[\d.]+' || echo "$live_tag")
  local desired_ver=$(echo "$desired_tag" | grep -oP '^[\d.]+' || echo "$desired_tag")

  if [[ "$live_ver" == "$desired_ver" ]]; then
    echo "   ✅ Same version ($live_ver) — compatible"
    return 0
  fi

  # Use should_migrate_by_version to detect major change + downgrade
  local migration_result
  migration_result=$(should_migrate_by_version "$live_ver" "$desired_ver" "major" 2>&1)
  local migration_code=$?

  if [[ $migration_code -eq 2 ]]; then
    # Downgrade detected
    echo ""
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    echo "🚨 DOWNGRADE DETECTED: $live_ver → $desired_ver"
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    echo "   Database downgrades risk data corruption and are NOT supported"
    echo "   by automated deployment."
    echo ""
    echo "   📋 To resolve:"
    echo "   1. Revert the image version in example.versions.env"
    echo "   2. Re-run the deployment pipeline"
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    return 4
  fi

  if [[ $migration_code -eq 0 ]]; then
    # Major version migration required
    echo ""
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    echo "🚨 MAJOR VERSION CHANGE: $live_ver → $desired_ver"
    echo "🚨 ═══════════════════════════════════════════════════════════════════"
    echo "   Major database version upgrades require careful planning."
    echo "   MariaDB major upgrades may include incompatible changes to:"
    echo "   • System table schemas     • Replication protocol"
    echo "   • Storage engine internals  • SQL syntax/behavior"
    echo ""
    echo "   📋 Manual upgrade procedure:"
    echo "   1. Back up all Galera PVCs and take a logical dump (mysqldump)"
    echo "   2. Review MariaDB release notes for $live_ver → $desired_ver"
    echo "   3. Test the upgrade in dev/test with production data snapshot"
    echo "   4. Scale Galera to 1 replica (single-node upgrade)"
    echo "   5. Set ALLOW_MAJOR_DB_UPGRADE=yes in the pipeline environment"
    echo "   6. Re-run the deployment — script will proceed with rolling upgrade"
    echo "   7. Run mysql_upgrade on the primary node after version change"
    echo "   8. Scale back to full replica count"
    echo "🚨 ═══════════════════════════════════════════════════════════════════"

    if [[ "$allow_major" == "yes" ]]; then
      echo ""
      echo "⚠️  ALLOW_MAJOR_DB_UPGRADE=yes — proceeding with major upgrade"
      echo "   Ensure you have backups and have tested this in a lower environment."
      return 2  # Still flag as major, but caller can proceed
    fi
    return 2
  fi

  # Minor/patch version change — safe for rolling update
  echo "   📈 Version change: $live_ver → $desired_ver (minor/patch — safe for rolling update)"
  return 1
}

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
