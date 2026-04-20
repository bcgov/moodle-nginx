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
  # $3 (expected_cluster_size) accepted for backward compatibility but unused.
  # Individual pod health is determined by Synced + Primary status, not cluster
  # size. Cluster-wide size convergence is verified in wait_for_galera_sync.

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
    -e "SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_cluster_status'; SHOW STATUS LIKE 'wsrep_cluster_size';" \
    2>/dev/null) || {
    echo "    [ERROR] MySQL connection failed for pod $pod_name"
    return 1
  }

  # Parse the status
  local local_state=$(echo "$galera_status" | awk '/wsrep_local_state_comment/ {print $2}')
  local cluster_status=$(echo "$galera_status" | awk '/wsrep_cluster_status/ {print $2}')
  local cluster_size=$(echo "$galera_status" | awk '/wsrep_cluster_size/ {print $2}')

  # Pod is healthy if it is Synced and part of a Primary component.
  # Cluster size is NOT checked here — a node can be individually healthy
  # even when another node is disconnected (size < expected). Cluster-wide
  # size convergence is verified separately in wait_for_galera_sync.
  if [[ "$local_state" == "Synced" && "$cluster_status" == "Primary" ]]; then
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

  echo "[WAIT] Waiting for Galera cluster to sync: $galera_name"

  local namespace="$DEPLOY_NAMESPACE"
  local selector="app.kubernetes.io/name=$galera_name"

  # Auto-detect expected pods if not provided
  if [[ -z "$expected_pods" ]]; then
    expected_pods=$(get_expected_replica_count "$selector" "$namespace")
    if [[ $? -ne 0 ]]; then
      echo "[ERROR] Failed to determine expected pod count" >&2
      return 1
    fi
    echo "  [INFO] Auto-detected expected pod count: $expected_pods"
  fi

  echo "[WAIT] Waiting for $galera_name resource to be ready..."

  # First wait for the StatefulSet to be ready (fast check using status fields)
  if ! wait_for_resource_ready "$selector" "$namespace" "$max_retries" "$wait_time" "Galera StatefulSet"; then
    echo "[ERROR] Galera StatefulSet failed to become ready" >&2
    return 1
  fi

  # Now verify Galera-specific health (cluster synchronization)
  echo "[OK] StatefulSet ready, now verifying Galera cluster synchronization..."

  # Fail fast if credentials are not available — retrying won't help
  if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "[WARN] DB_PASSWORD not set - cannot verify Galera sync (skipping)"
    echo "  [INFO] StatefulSet is ready; Galera sync verification requires database credentials"
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
        # Final check: verify cluster_size matches expected on all pods
        local size_ok=true
        for pod in "${pods[@]}"; do
          local csize
          csize=$(oc exec -n "$namespace" "$pod" -- \
            mysql -u "${DB_USER:-root}" -p"$DB_PASSWORD" \
            -e "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null \
            | awk '/wsrep_cluster_size/ {print $2}')
          if [[ "$csize" != "$expected_pods" ]]; then
            size_ok=false
            break
          fi
        done
        if $size_ok; then
          echo "[OK] All $expected_pods Galera pods are healthy, synced, and cluster_size=$expected_pods"
          return 0
        else
          echo "    $healthy_pods/$expected_pods pods Synced/Primary but cluster_size not yet converged... (retry $retries/$max_retries)"
        fi
      else
        echo "    $healthy_pods/$expected_pods pods are Galera-ready... (retry $retries/$max_retries)"

        # --- Auto-recovery: detect and restart pods stuck in Disconnected/Initialized ---
        if [[ $healthy_pods -gt 0 && $retries -gt 2 ]]; then
          for pod in "${pods[@]}"; do
            if check_galera_pod_ready "$pod" "$namespace"; then
              continue  # This pod is fine
            fi
            # Query the stuck pod's wsrep state
            local pod_wsrep
            pod_wsrep=$(oc exec -n "$namespace" "$pod" -- \
              mysql -u "${DB_USER:-root}" -p"$DB_PASSWORD" \
              -e "SHOW STATUS LIKE 'wsrep_local_state_comment'; SHOW STATUS LIKE 'wsrep_cluster_status';" \
              2>/dev/null) || continue
            local pstate=$(echo "$pod_wsrep" | awk '/wsrep_local_state_comment/ {print $2}')
            local pcluster=$(echo "$pod_wsrep" | awk '/wsrep_cluster_status/ {print $2}')
            if [[ "$pstate" == "Initialized" && "$pcluster" == "Disconnected" ]]; then
              echo "    [AUTO-HEAL] $pod stuck in Initialized/Disconnected — deleting pod for clean rejoin"
              oc delete pod "$pod" -n "$namespace" --grace-period=30 2>/dev/null
              sleep 5  # Brief pause before continuing the wait loop
            fi
          done
        fi
      fi
    else
      echo "    Pod count mismatch: found $pod_count, expected $expected_pods (retry $retries/$max_retries)"
    fi

    retries=$((retries + 1))
    sleep $wait_time
  done

  echo "[WARN] Timeout: Galera cluster did not synchronize after $((max_retries * wait_time)) seconds"
  return 1
}

# Enhanced Galera cluster health check with split-brain detection
#
# This function distinguishes between TRUE SPLIT-BRAIN (emergency) and
# temporary network partitions (self-healing):
#
# SPLIT-BRAIN DETECTION:
#   - TRUE SPLIT-BRAIN: Multiple cluster UUIDs = independent clusters with
#     divergent data. This requires emergency intervention (return 2).
#   - NETWORK PARTITION: Same UUID but different cluster_sizes = temporary
#     isolation during rolling updates, pod restarts, or network issues.
#     If quorum exists, this is NORMAL and will self-heal (return 0).
#
# RETURN CODES:
#   0 = Healthy (all pods synced OR partition with quorum that will self-heal)
#   1 = Unhealthy (pods failing health checks OR partition without quorum)
#   2 = TRUE SPLIT-BRAIN (multiple UUIDs - data divergence risk, emergency)
#
# IMPORTANT: Only return code 2 should trigger emergency cluster rebuild.
# Return code 1 may resolve on its own as pods rejoin.
#
check_galera_cluster_health() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-}"

  # Dynamically determine expected size if not provided
  if [[ -z "$expected_size" ]]; then
    expected_size=$(get_expected_replica_count "$selector" "$namespace")
    if [[ $? -ne 0 ]]; then
      echo "[ERROR] Failed to determine expected cluster size" >&2
      return 1
    fi
    echo "  [INFO] Auto-detected expected cluster size: $expected_size"
  fi

  # Validate database credentials before proceeding — avoids false positives
  if [[ -z "${DB_PASSWORD:-}" ]]; then
    echo "  [WARN] DB_PASSWORD not set - skipping Galera health check (cannot authenticate to MySQL)" >&2
    return 0
  fi

  # Get running pods using the selector
  local pods=( $(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[*].metadata.name}') )

  if [[ ${#pods[@]} -eq 0 ]]; then
    # CRITICAL: No running pods - check if this is intentional (replicas=0) or a crash
    if [[ "$expected_size" -eq 0 ]]; then
      echo "  [INFO] No running Galera pods (expected: 0 replicas = intentional shutdown)"
      return 0  # Intentional - no action needed
    else
      # Expected pods but none running - check for CrashLoopBackOff
      echo "  [CRITICAL] Expected $expected_size Galera pods but found 0 running"

      # Check if pods exist but are crashing
      local all_pods
      all_pods=$(oc get pods -l "$selector" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

      if [[ -n "$all_pods" ]]; then
        # Pods exist - check their state
        local crash_count=0
        for pod in $all_pods; do
          local pod_state
          pod_state=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].state}' 2>/dev/null)

          if echo "$pod_state" | grep -q "CrashLoopBackOff\|Error"; then
            local reason
            reason=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)
            echo "    [ERROR] $pod: $reason (requires auto-heal)"
            crash_count=$((crash_count + 1))
          fi
        done

        if [[ $crash_count -gt 0 ]]; then
          send_notification "GALERA_ALL_PODS_CRASHED" "All Galera Pods Crashed" \
            "All $expected_size Galera pods are in CrashLoopBackOff in $namespace. This typically indicates safe_to_bootstrap issue. Auto-heal will attempt recovery." \
            "error" "$namespace"
          return 1  # Trigger auto-heal
        fi
      else
        # No pods exist at all - likely scaling issue
        echo "  [WARN] No Galera pods exist (StatefulSet may need attention)"
        return 1  # Trigger auto-heal
      fi

      # Unknown state - be conservative
      echo "  [WARN] Unable to determine pod state - assuming unhealthy"
      return 1
    fi
  fi

  # Verify running pods match expected count
  if [[ ${#pods[@]} -eq $expected_size ]]; then
    echo "  [OK] All $expected_size Galera pod(s) are running"
  else
    echo "  [WARN] Pod count mismatch: ${#pods[@]} running, $expected_size expected"
  fi

  echo "  [CHECK] Checking Galera cluster health for ${#pods[@]} pods..."

  local healthy_pods=0
  local uuids=()
  local sizes=()
  local states=()
  local detailed_status=""

  # Check each pod using existing utility function
  for pod in "${pods[@]}"; do
    if check_galera_pod_ready "$pod" "$namespace" "$expected_size"; then
      healthy_pods=$((healthy_pods + 1))
      echo "    [OK] $pod: healthy and synced"
    else
      echo "    [ERROR] $pod: unhealthy or not synced"
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

  # TRUE SPLIT-BRAIN: Multiple cluster UUIDs = independent clusters with divergent data
  # This is the ONLY condition that requires emergency rebuild (data loss risk)
  if [[ $unique_uuids -gt 1 ]]; then
    send_notification "GALERA_SPLIT_BRAIN_DETECTED" "Galera Split-Brain Detected" "TRUE SPLIT-BRAIN: Multiple cluster UUIDs detected! UUIDs: $unique_uuids. Details: $detailed_status" "error" "$namespace"
    return 2  # Split-brain detected
  fi

  # NETWORK PARTITION: Same UUID but different cluster sizes
  # This is NORMAL during rolling updates, pod restarts, or temporary network issues.
  # As long as UUIDs match, pods will rejoin automatically when network is restored.
  if [[ $unique_sizes -gt 1 ]]; then
    echo "    [WARN] Cluster size mismatch (sizes: $(printf "%s\n" "${sizes[@]}" | sort | uniq | tr '\n' ' '))"
    echo "    [INFO] All pods share same UUID - this is a network partition, NOT split-brain"

    # Check if we have quorum (majority of nodes agree on cluster size)
    local max_size=0
    local max_count=0
    for size in "${sizes[@]}"; do
      local count=$(printf "%s\n" "${sizes[@]}" | grep -c "^$size$")
      if [[ $count -gt $max_count ]]; then
        max_size=$size
        max_count=$count
      fi
    done

    if [[ $max_size -ge $((expected_size - 1)) && $max_count -ge $((expected_size / 2 + 1)) ]]; then
      echo "    [OK] Quorum exists: $max_count pods agree on cluster_size=$max_size"
      echo "    [INFO] Isolated pods will rejoin automatically - no intervention needed"
      send_notification "GALERA_NETWORK_PARTITION" "Galera Network Partition (Auto-Healing)" "Temporary partition detected but quorum exists ($max_count pods, size=$max_size). Isolated pods will rejoin. Details: $detailed_status" "info" "$namespace"
      return 0  # Healthy - partition will self-heal
    else
      echo "    [WARN] No quorum - cluster needs attention"
      send_notification "GALERA_NO_QUORUM" "Galera No Quorum" "Cluster size mismatch without quorum. Details: $detailed_status" "warning" "$namespace"
      return 1  # Unhealthy but not split-brain
    fi
  fi

  # Check overall pod health
  if [[ $healthy_pods -lt $expected_size ]]; then
    send_notification "GALERA_UNHEALTHY_PODS" "Galera Pods Unhealthy" "Some pods unhealthy: $healthy_pods/$expected_size healthy. Details: $detailed_status" "warning" "$namespace"
    return 1  # Some pods unhealthy
  else
    echo "    [OK] Galera cluster healthy: all $healthy_pods pods synced and consistent"
    return 0  # All healthy
  fi
}

# Function to auto-heal Galera cluster using galera_safe_upgrade()
# Delegates to the shared upgrade function for consistent behavior
# across deploy scripts and health monitoring.
auto_heal_galera_cluster() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local now_epoch
  now_epoch=$(date +%s)

  # Loop protection knobs (override with env vars when needed)
  local heal_lock_ttl="${GALERA_AUTO_HEAL_LOCK_TTL_SECONDS:-1800}"
  local heal_failure_cooldown="${GALERA_AUTO_HEAL_FAILURE_COOLDOWN_SECONDS:-900}"
  local enable_failsafe="${GALERA_AUTO_HEAL_ENABLE_FAILSAFE:-true}"
  local failsafe_replicas="${GALERA_AUTO_HEAL_FAILSAFE_SCALE_REPLICAS:-0}"
  local failsafe_set_manual_mode="${GALERA_AUTO_HEAL_FAILSAFE_SET_MANUAL_MODE:-true}"
  local auto_enable_maintenance="${AUTO_ENABLE_MAINTENANCE:-true}"
  local auto_enable_moodle_maintenance="${AUTO_ENABLE_MOODLE_MAINTENANCE:-YES}"
  local auto_enable_openshift_maintenance="${AUTO_ENABLE_OPENSHIFT_MAINTENANCE:-YES}"
  local auto_maintenance_timeout_minutes="${AUTO_MAINTENANCE_TIMEOUT_MINUTES:-240}"
  local lock_annotation_key="galera-auto-heal-lock-epoch"
  local failure_annotation_key="galera-auto-heal-last-failure-epoch"

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

  # Cooldown protection: skip repeated failed repairs for a short period
  local last_failure_epoch
  last_failure_epoch=$(oc get statefulset "$resource_name" -n "$namespace" \
    -o jsonpath="{.metadata.annotations.${failure_annotation_key}}" 2>/dev/null || echo "")
  if [[ "$last_failure_epoch" =~ ^[0-9]+$ ]]; then
    local fail_age=$((now_epoch - last_failure_epoch))
    if [[ $fail_age -lt $heal_failure_cooldown ]]; then
      echo "⏸️  Auto-heal cooldown active (${fail_age}s/${heal_failure_cooldown}s since last failed attempt)"
      echo "    Skipping this cycle to avoid repeated failed recovery loops"
      send_notification "GALERA_AUTO_HEAL_COOLDOWN" "Auto-Heal Cooldown Active" "Skipping auto-heal for statefulset/$resource_name: last failure ${fail_age}s ago (cooldown ${heal_failure_cooldown}s)" "info" "$namespace"
      return 1
    fi
  fi

  # Cross-pod lock: prevent overlapping auto-heal executions
  local lock_epoch
  lock_epoch=$(oc get statefulset "$resource_name" -n "$namespace" \
    -o jsonpath="{.metadata.annotations.${lock_annotation_key}}" 2>/dev/null || echo "")
  if [[ "$lock_epoch" =~ ^[0-9]+$ ]]; then
    local lock_age=$((now_epoch - lock_epoch))
    if [[ $lock_age -lt $heal_lock_ttl ]]; then
      echo "⏳ Auto-heal lock already held (${lock_age}s/${heal_lock_ttl}s) - skipping duplicate run"
      send_notification "GALERA_AUTO_HEAL_LOCKED" "Auto-Heal Already Running" "Skipping duplicate auto-heal for statefulset/$resource_name: lock age ${lock_age}s" "info" "$namespace"
      return 1
    else
      echo "⚠️  Found stale auto-heal lock (${lock_age}s old) - clearing it"
      oc annotate statefulset/"$resource_name" -n "$namespace" "${lock_annotation_key}-" &>/dev/null || true
    fi
  fi

  # Acquire lock
  oc annotate statefulset/"$resource_name" -n "$namespace" \
    "${lock_annotation_key}=${now_epoch}" --overwrite &>/dev/null || {
    echo "⚠️  Could not acquire auto-heal lock; skipping this cycle"
    return 1
  }

  # Determine stable recovery target:
  # sizing CSV (source of truth) -> annotation -> live replicas -> env default
  local original_replicas

  # Primary: sizing CSV via shared utility (same source as right-sizing.sh)
  original_replicas=$(get_sizing_replicas "$resource_name" "$namespace")
  if [[ -n "$original_replicas" && "$original_replicas" =~ ^[0-9]+$ && "$original_replicas" -gt 0 ]]; then
    echo "[INFO] Using sizing CSV target replicas: $original_replicas"
  else
    original_replicas=""
  fi

  # Fallback: last-known annotation
  if [[ -z "$original_replicas" ]]; then
    original_replicas=$(oc get statefulset "$resource_name" -n "$namespace" \
      -o jsonpath='{.metadata.annotations.last-known-replicas}' 2>/dev/null || echo "")
    if [[ -n "$original_replicas" && "$original_replicas" =~ ^[0-9]+$ && "$original_replicas" -gt 0 ]]; then
      echo "[INFO] Using last-known annotation target replicas: $original_replicas"
    else
      original_replicas=""
    fi
  fi

  # Fallback: live spec (may be 0 or 1 during recovery - used only if CSV/annotation unavailable)
  if [[ -z "$original_replicas" ]]; then
    original_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "")
  fi

  # Final hardcoded fallback by environment
  if [[ -z "$original_replicas" || ! "$original_replicas" =~ ^[0-9]+$ || "$original_replicas" -le 0 ]]; then
    case "$namespace" in
      950003-prod) original_replicas=5 ;;
      950003-test|950003-dev) original_replicas=5 ;;
      *) original_replicas=2 ;;
    esac
  fi

  if [[ -z "$original_replicas" || "$original_replicas" == "0" ]]; then
    oc annotate statefulset/"$resource_name" -n "$namespace" "${lock_annotation_key}-" &>/dev/null || true
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - Invalid Replicas" "Could not determine valid replica count for statefulset: $resource_name" "error" "$namespace"
    return 1
  fi

  send_notification "GALERA_AUTO_HEAL_SCALING" "Starting Auto-Heal Process" "Auto-healing statefulset/$resource_name: safe upgrade cycle to $original_replicas replicas" "healing" "$namespace"

  # Step 0.1: Verify and fix cluster address configuration (prevents split-brain on scale-up)
  echo ""
  echo "Pre-flight check 1: Verifying cluster address configuration..."
  galera_verify_cluster_address "$resource_name" "$namespace" "fix"

  # Step 0.2: Verify timeout configuration (informational only)
  echo ""
  echo "Pre-flight check 2: Verifying Galera timeout configuration..."
  galera_verify_timeouts "$resource_name" "$namespace" "verify"
  local timeout_result=$?
  if [[ $timeout_result -eq 0 ]]; then
    echo "   ✅ Timeout configuration verified"
  else
    echo "   ℹ️  No PT30S timeouts configured (configure via my.cnf or Helm values)"
  fi

  # Step 0.3: Clean up any stale MARIADB_EXTRA_FLAGS from prior failed recovery.
  # --wsrep-provider-options via EXTRA_FLAGS replaces Galera's entire base config,
  # causing segfaults on SST. Always remove to ensure a clean template.
  local stale_extra_flags
  stale_extra_flags=$(oc get statefulset/"$resource_name" -n "$namespace" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MARIADB_EXTRA_FLAGS")].value}' 2>/dev/null || echo "")
  if [[ -n "$stale_extra_flags" ]]; then
    echo ""
    echo "Pre-flight check 3: Removing stale MARIADB_EXTRA_FLAGS..."
    echo "   Was: $stale_extra_flags"
    oc set env statefulset/"$resource_name" MARIADB_EXTRA_FLAGS- -n "$namespace" 2>/dev/null || true
    echo "   ✅ Removed"
  fi

  # Step 0.4: Reset stale partition from prior failed recovery.
  # Partition=1 blocks galera-0 from restarting; a failed recovery may leave it set.
  local stale_partition
  stale_partition=$(oc get statefulset/"$resource_name" -n "$namespace" \
    -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}' 2>/dev/null || echo "0")
  if [[ "$stale_partition" != "0" && -n "$stale_partition" ]]; then
    echo ""
    echo "Pre-flight check 4: Resetting stale partition ($stale_partition -> 0)..."
    oc patch statefulset/"$resource_name" -n "$namespace" \
      -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}' 2>/dev/null || true
    echo "   ✅ Partition reset"
  fi

  # Delegate to galera_safe_upgrade for the actual work
  if galera_safe_upgrade "$resource_name" "$original_replicas" "$namespace"; then
    oc annotate statefulset/"$resource_name" -n "$namespace" \
      "${failure_annotation_key}-" "${lock_annotation_key}-" &>/dev/null || true
    send_notification "GALERA_AUTO_HEAL_SUCCESS" "Auto-Heal Successful" "Successfully auto-healed statefulset/$resource_name: all $original_replicas replicas are healthy and synced" "success" "$namespace"
    return 0
  else
    oc annotate statefulset/"$resource_name" -n "$namespace" \
      "${failure_annotation_key}=${now_epoch}" --overwrite &>/dev/null || true
    oc annotate statefulset/"$resource_name" -n "$namespace" "${lock_annotation_key}-" &>/dev/null || true

    # Failsafe mode: park cluster and disable further auto-healing until manual re-enable.
    if [[ "${enable_failsafe,,}" == "true" ]]; then
      echo ""
      echo "FAILSAFE: Auto-heal failed. Parking cluster in safe state to reduce alert noise..."

      # Defensive reset: ensure failed node cannot keep trying bootstrap.
      oc set env statefulset/"$resource_name" \
        "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
        "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
        -n "$namespace" 2>/dev/null || true

      # Default is 0 to stop CrashLoopBackOff churn and alert noise.
      if [[ "$failsafe_replicas" =~ ^[0-9]+$ ]]; then
        echo "   Scaling statefulset/$resource_name to failsafe replicas: $failsafe_replicas"
        oc scale statefulset/"$resource_name" --replicas="$failsafe_replicas" -n "$namespace" 2>/dev/null || true
      else
        echo "   Invalid GALERA_AUTO_HEAL_FAILSAFE_SCALE_REPLICAS='$failsafe_replicas' (expected integer)"
      fi

      # Auto-disable monitor healing path until developer re-enables MANUAL_MODE=false.
      if [[ "${failsafe_set_manual_mode,,}" == "true" ]]; then
        echo "   Setting pod-health-monitor MANUAL_MODE=true"
        oc set env deployment/pod-health-monitor MANUAL_MODE=true -n "$namespace" 2>/dev/null || true
      fi

      # Optional maintenance-mode automation based on failsafe end-state.
      # Policy:
      #   - replicas=0 -> always enable maintenance (site cannot function)
      #   - replicas=1 -> keep site accessible if Galera is healthy at 1/1; enable maintenance only if unhealthy
      #   - replicas>1 -> no maintenance here (already attempting normal availability)
      if [[ "${auto_enable_maintenance,,}" == "true" ]]; then
        if [[ "$failsafe_replicas" == "0" ]]; then
          echo "   AUTO_ENABLE_MAINTENANCE=true and replicas=0 -> enabling maintenance mode"
          if command -v enable_emergency_maintenance >/dev/null 2>&1; then
            enable_emergency_maintenance "$namespace" \
              "Auto-heal failed and Galera scaled to 0 replicas" \
              "$auto_enable_moodle_maintenance" \
              "$auto_enable_openshift_maintenance" \
              "$auto_maintenance_timeout_minutes" || true
          else
            send_notification "GALERA_AUTO_HEAL_MAINTENANCE_SKIPPED" \
              "Maintenance Automation Unavailable" \
              "AUTO_ENABLE_MAINTENANCE=true but enable_emergency_maintenance function is unavailable in monitor runtime." \
              "warning" "$namespace"
          fi
        elif [[ "$failsafe_replicas" == "1" ]]; then
          echo "   Failsafe replicas=1 -> verifying 1/1 Galera health before maintenance decision"
          sleep 10
          check_galera_cluster_health "app.kubernetes.io/name=$resource_name" "$namespace" "1" >/dev/null 2>&1
          local single_health=$?
          if [[ $single_health -eq 0 ]]; then
            echo "   Single-node Galera is healthy (1/1); leaving site accessible"
            send_notification "GALERA_DEGRADED_SINGLE_NODE" \
              "Galera Degraded to Single Node" \
              "Auto-heal failed and failsafe scaled to 1 replica. Cluster is functional at reduced availability; site remains accessible." \
              "warning" "$namespace"
          else
            echo "   Single-node Galera is unhealthy; enabling maintenance mode"
            if command -v enable_emergency_maintenance >/dev/null 2>&1; then
              enable_emergency_maintenance "$namespace" \
                "Auto-heal failed; single-node Galera unhealthy after failsafe" \
                "$auto_enable_moodle_maintenance" \
                "$auto_enable_openshift_maintenance" \
                "$auto_maintenance_timeout_minutes" || true
            else
              send_notification "GALERA_AUTO_HEAL_MAINTENANCE_SKIPPED" \
                "Maintenance Automation Unavailable" \
                "AUTO_ENABLE_MAINTENANCE=true but enable_emergency_maintenance function is unavailable in monitor runtime." \
                "warning" "$namespace"
            fi
          fi
        else
          send_notification "GALERA_AUTO_HEAL_FAILSAFE" \
            "Auto-Heal Failsafe Applied" \
            "Auto-heal failed; failsafe applied with replicas=$failsafe_replicas. Maintenance mode was not auto-enabled for this replica target." \
            "warning" "$namespace"
        fi
      else
        send_notification "GALERA_AUTO_HEAL_MAINTENANCE_DISABLED" \
          "Maintenance Automation Disabled" \
          "AUTO_ENABLE_MAINTENANCE=false. Failsafe applied without enabling maintenance mode." \
          "info" "$namespace"
      fi

      send_notification "GALERA_AUTO_HEAL_FAILSAFE_LOCKDOWN" \
        "Auto-Heal Failsafe Activated" \
        "Auto-heal failed for statefulset/$resource_name. Applied failsafe: scaled to $failsafe_replicas and set MANUAL_MODE=true (if enabled). Manual intervention required." \
        "warning" "$namespace"
    fi

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

  # Determine whether cluster is intentionally parked/offline in manual mode
  local manual_mode_active="${MANUAL_MODE:-false}"
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi
  local actual_replicas
  actual_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "$expected_size")

  case $health_code in
    0)
      if [[ "$actual_replicas" == "0" ]]; then
        echo "[INFO] Galera is intentionally parked at 0 replicas"
        if [[ "${manual_mode_active,,}" == "true" ]]; then
          echo "[INFO] MANUAL MODE is active - auto-healing remains disabled until re-enabled by a developer"
        fi
      elif [[ "$actual_replicas" == "1" && "$expected_size" -gt 1 ]]; then
        echo "[WARN] Galera is running in degraded single-node mode (1/$expected_size)"
        echo "[INFO] Site may be accessible but redundancy is reduced"
      else
        echo "[OK] Galera cluster is healthy - no action needed"
      fi
      return 0
      ;;
    1)
      echo "[WARN] Some Galera pods are unhealthy (or network partition without quorum)"
      if [[ "$auto_heal" == "true" ]]; then
        echo "[ACTION] Attempting auto-heal..."
        auto_heal_galera_cluster "$selector" "$namespace"
      else
        echo "  [INFO] Auto-heal disabled - manual intervention may be required"
      fi
      ;;
    2)
      echo "[CRITICAL] SPLIT-BRAIN detected in Galera cluster (multiple cluster UUIDs)"
      echo "  [WARN] Data divergence risk - emergency rebuild required"
      if [[ "$auto_heal" == "true" ]]; then
        echo "[ACTION] Attempting emergency auto-heal for split-brain..."
        auto_heal_galera_cluster "$selector" "$namespace"
      else
        echo "  [WARN] Auto-heal disabled - MANUAL INTERVENTION REQUIRED IMMEDIATELY"
        echo "  [INFO] See docs/manual-galera-troubleshooting.md"
      fi
      ;;
    *)
      echo "Unknown health check result"
      return 1
      ;;
  esac
}

# =============================================================================
# GALERA CLUSTER ADDRESS VERIFICATION AND FIX
# =============================================================================

# Verify and optionally fix MARIADB_GALERA_CLUSTER_ADDRESS configuration.
# Prevents split-brain where nodes 1-4 bootstrap independently instead of
# joining node 0.
#
# Arguments:
#   $1 - StatefulSet name
#   $2 - Namespace
#   $3 - "fix" to apply corrections automatically (optional)
#
# Returns:
#   0 = configuration is correct
#   1 = issues found and fixed (if fix mode)
#   2 = issues found but not fixed (diagnostic mode)
galera_verify_cluster_address() {
  local sts_name="$1"
  local namespace="$2"
  local fix_mode="${3:-}"
  local target_replicas="${4:-}"

  echo ""
  echo "Verifying MARIADB_GALERA_CLUSTER_ADDRESS configuration..."

  # Path resolution: Support both natural subdirectories and flattened paths
  # - Natural:   /scripts/utils/galera-fix-cluster-address.sh  (future: volumeMount.items[].path)
  # - Flattened: /scripts/utils-galera-fix-cluster-address.sh  (current: ConfigMap key limitation)
  # See: docs/galera-deployment-best-practices.md#configmap-path-strategy
  local script_path=""
  if [[ -f "/scripts/utils/galera-fix-cluster-address.sh" ]]; then
    script_path="/scripts/utils/galera-fix-cluster-address.sh"  # Preferred (natural structure)
  elif [[ -f "/scripts/utils-galera-fix-cluster-address.sh" ]]; then
    script_path="/scripts/utils-galera-fix-cluster-address.sh"  # Fallback (flattened)
  fi
  if [[ ! -f "$script_path" ]]; then
    echo "   Warning: $script_path not found, skipping cluster address check"
    return 0
  fi

  local fix_flag=""
  if [[ "$fix_mode" == "fix" ]]; then
    fix_flag="--fix"
  fi

  # Run the fix script
  local verify_exit_code=0
  if [[ -n "$target_replicas" ]]; then
    GALERA_TARGET_REPLICAS="$target_replicas" bash "$script_path" "$namespace" "$sts_name" $fix_flag
    verify_exit_code=$?
  else
    bash "$script_path" "$namespace" "$sts_name" $fix_flag
    verify_exit_code=$?
  fi

  if [[ $verify_exit_code -eq 0 ]]; then
    echo "   ✅ Cluster address configuration is correct"
    return 0
  else
    if [[ $verify_exit_code -eq 1 ]]; then
      echo "   ✅ Issues were detected and corrected"
      return 1
    else
      echo "   ⚠️  Issues detected but not fixed (diagnostic mode)"
      return 2
    fi
  fi
}

# =============================================================================
# GALERA TIMEOUT CONFIGURATION
# =============================================================================

# Verify and optionally apply PT30S timeout configuration to prevent split-brain.
# Checks if proper Galera timeouts are configured (via MARIADB_EXTRA_FLAGS or my.cnf).
# If not configured, applies PT30S settings via MARIADB_EXTRA_FLAGS.
#
# Background:
#   - Default Galera timeouts (PT15S) are too aggressive for slow storage/network
#   - PT30S prevents premature node eviction during slow I/O operations
#   - MARIADB_EXTRA_FLAGS overrides my.cnf settings (runtime configuration)
#   - See: openshift/scripts/test-clear-extraflags.sh for implementation details
#
# Arguments:
#   $1 - StatefulSet name (e.g., mariadb-galera)
#   $2 - Namespace
#   $3 - "apply" to set MARIADB_EXTRA_FLAGS if missing (optional, default: verify only)
#
# Returns:
#   0 = PT30S configured (or applied successfully)
#   1 = PT30S not configured (verification mode)
#   2 = Failed to apply configuration
galera_verify_timeouts() {
  local sts_name="$1"
  local namespace="$2"
  local apply_mode="${3:-}"

  echo "Verifying Galera timeout configuration..."

  # Check if any pods are running to verify actual configuration
  local pod_0="${sts_name}-0"
  if oc get pod "$pod_0" -n "$namespace" &>/dev/null; then
    local pod_phase
    pod_phase=$(oc get pod "$pod_0" -n "$namespace" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "$pod_phase" == "Running" ]]; then
      # Check what's actually running in the process
      local running_config
      running_config=$(oc exec "$pod_0" -n "$namespace" -c "$sts_name" -- \
        ps aux 2>/dev/null | grep "wsrep-provider-options" | grep -v grep | head -1 || echo "")

      if [[ "$running_config" =~ PT30S ]]; then
        echo "   ✅ PT30S timeouts active in running process"
        return 0
      elif [[ "$running_config" =~ PT20S ]]; then
        echo "   ℹ️  PT20S timeouts active (from ConfigMap)"
        echo "   Acceptable for production - no change needed"
        return 0
      elif [[ "$running_config" =~ PT15S ]]; then
        echo "   ⚠️  PT15S timeouts (MariaDB defaults) - too aggressive for production"
      else
        echo "   ⚠️  Could not detect timeout configuration from running process"
      fi
    fi
  fi

  # Check StatefulSet environment variables
  local current_flags
  current_flags=$(oc get statefulset/"$sts_name" -n "$namespace" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"$sts_name"'")].env[?(@.name=="MARIADB_EXTRA_FLAGS")].value}' 2>/dev/null)

  if [[ "$current_flags" =~ PT30S ]]; then
    echo "   ✅ MARIADB_EXTRA_FLAGS configured with PT30S in StatefulSet template"
    return 0
  elif [[ "$current_flags" =~ PT20S ]]; then
    echo "   ✅ MARIADB_EXTRA_FLAGS configured with PT20S in StatefulSet template"
    return 0
  fi

  # Check if ConfigMap has timeout configuration
  if oc get configmap "$sts_name" -n "$namespace" &>/dev/null; then
    local configmap_data
    configmap_data=$(oc get configmap "$sts_name" -n "$namespace" -o yaml 2>/dev/null | grep -E "evs\.(suspect|inactive|install)_timeout" || echo "")

    if [[ "$configmap_data" =~ PT30S ]] || [[ "$configmap_data" =~ PT20S ]]; then
      echo "   ✅ Timeouts configured in ConfigMap (PT20S or PT30S)"
      return 0
    fi
  fi

  # No proper timeout configuration found
  echo "   ⚠️  No PT30S/PT20S timeout configuration detected"
  echo "   Current environment: MARIADB_EXTRA_FLAGS=${current_flags:-<not set>}"

  if [[ "$apply_mode" != "apply" ]]; then
    echo "   Verification mode - not applying changes"
    echo "   To apply PT30S: galera_verify_timeouts \"$sts_name\" \"$namespace\" \"apply\""
    return 1
  fi

  # DEPRECATED: Do NOT apply PT30S via MARIADB_EXTRA_FLAGS.
  # --wsrep-provider-options REPLACES the entire provider options string, stripping
  # Galera's base config (gcache, gcomm, base_host, etc.) and causing segfaults on SST.
  # Timeout tuning must be done via my.cnf ConfigMap or Helm values instead.
  echo ""
  echo "   ⚠️  No PT30S/PT20S timeout configuration detected"
  echo "   MARIADB_EXTRA_FLAGS cannot be used for wsrep-provider-options (causes segfaults)"
  echo "   Configure timeouts via Helm values or my.cnf ConfigMap instead"
  return 1
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

    # Check if galera-0 is stuck in Init phase (volume attachment issues, etc.)
    if [[ "$pod_0_phase" == "Pending" ]]; then
      # Check init container status
      local init_container_state
      init_container_state=$(oc get pod "$pod_0" -n "$namespace" \
        -o jsonpath='{.status.initContainerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")

      # Check how long pod has been stuck
      local pod_start_time
      pod_start_time=$(oc get pod "$pod_0" -n "$namespace" \
        -o jsonpath='{.status.startTime}' 2>/dev/null || echo "")

      if [[ -n "$pod_start_time" ]]; then
        local now_epoch
        now_epoch=$(date +%s)
        local start_epoch
        start_epoch=$(date -d "$pod_start_time" +%s 2>/dev/null || echo "$now_epoch")
        local stuck_duration=$((now_epoch - start_epoch))

        # If stuck in Init for more than 5 minutes, treat as failure
        if [[ $stuck_duration -gt 300 ]]; then
          echo "   galera-0: Stuck in Init phase for ${stuck_duration}s (threshold: 300s)"
          echo "   Init container state: ${init_container_state:-unknown}"
          echo "   This typically indicates volume attachment issues or init failures"
          echo "   Recovery will: scale to 0 (clean volume detachment), verify safe_to_bootstrap, scale up"
          return 0  # ALLOW recovery to proceed
        fi
      fi
    fi

    # Check if galera-0 specifically is in CrashLoopBackOff with safe_to_bootstrap issue
    local pod_0_container_state
    pod_0_container_state=$(oc get pod "$pod_0" -n "$namespace" \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null || echo "")

    if [[ "$pod_0_container_state" == "CrashLoopBackOff" ]]; then
      local pod_0_logs
      pod_0_logs=$(oc logs "$pod_0" -n "$namespace" --tail=100 2>/dev/null || echo "")

      if echo "$pod_0_logs" | grep -q -E "safe_to_bootstrap.*0|not safe to bootstrap"; then
        echo "   galera-0: CrashLoopBackOff (safe_to_bootstrap issue detected)"
        echo "   This indicates galera-0 cannot bootstrap while other nodes may be running"
        echo "   Recovery will: scale to 0, fix grastate.dat on galera-0, delete secondary PVCs, and rebuild"
        echo "   galera-0's PVC data will be used as the authoritative source"
        return 0  # ALLOW recovery to proceed
      fi
    fi

    # Check if ALL pods are in CrashLoopBackOff (complete cluster failure)
    local all_pods
    all_pods=$(oc get pods -l "app.kubernetes.io/name=$sts_name" -n "$namespace" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

    if [[ -n "$all_pods" ]]; then
      local crash_count=0
      local total_count=0

      for pod in $all_pods; do
        total_count=$((total_count + 1))
        local container_state
        container_state=$(oc get pod "$pod" -n "$namespace" \
          -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

        if [[ "$container_state" == "CrashLoopBackOff" ]]; then
          crash_count=$((crash_count + 1))

          # Check logs for safe_to_bootstrap error
          local recent_logs
          recent_logs=$(oc logs "$pod" -n "$namespace" --tail=50 2>/dev/null || echo "")

          if echo "$recent_logs" | grep -q "safe_to_bootstrap.*0"; then
            echo "   $pod: CrashLoopBackOff (safe_to_bootstrap issue detected)"
          elif echo "$recent_logs" | grep -q "not safe to bootstrap"; then
            echo "   $pod: CrashLoopBackOff (safe_to_bootstrap issue detected)"
          else
            echo "   $pod: CrashLoopBackOff"
          fi
        fi
      done

      # If ALL pods are crashing, this is complete cluster failure
      # Proceed with recovery (scale to 0 will fix it)
      if [[ $crash_count -eq $total_count && $crash_count -gt 0 ]]; then
        echo "   All $crash_count pods are in CrashLoopBackOff"
        echo "   This typically indicates safe_to_bootstrap issue - proceeding with recovery"
        echo "   Recovery will: scale to 0, fix grastate.dat, and rebuild cluster"
        return 0  # ALLOW recovery to proceed
      fi
    fi

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
    echo "   Pod may be starting up or in crash loop"

    # Check if this is a CrashLoopBackOff scenario - allow recovery for ANY crash
    # Crash reasons include: safe_to_bootstrap, config errors, plugin issues, etc.
    # Scale-to-0 recovery will fix config issues and reset the environment
    local container_state
    container_state=$(oc get pod "$pod_0" -n "$namespace" \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}' 2>/dev/null)

    if [[ "$container_state" == "CrashLoopBackOff" ]]; then
      echo "   ✅ CrashLoopBackOff detected - allowing recovery to proceed"
      echo "   Recovery will: scale to 0, clear bad config, fix grastate.dat, rebuild cluster"

      # Show last few log lines for diagnostics (don't block recovery)
      local recent_logs
      recent_logs=$(oc logs "$pod_0" -n "$namespace" --tail=20 2>/dev/null || echo "")
      if [[ -n "$recent_logs" ]]; then
        echo "   Last crash reason (from logs):"
        echo "$recent_logs" | grep -E "ERROR|FATAL|Aborting" | tail -3 | sed 's/^/     /'
      fi

      return 0  # ALLOW recovery to proceed
    fi

    # Common degraded case: pod is Running but not database-ready (NON-PRIMARY/startup loop).
    # If galera-0 is the only running pod, allow controlled recovery from galera-0 PVC.
    local running_count
    running_count=$(wc -w <<< "$running_pods" | tr -d ' ')
    local pod_ready
    pod_ready=$(oc get pod "$pod_0" -n "$namespace" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")

    if [[ "$running_count" == "1" && "$running_pods" == "$pod_0" ]]; then
      echo "   ✅ galera-0 is the only running pod; allowing controlled recovery to proceed"
      echo "   Recovery will: scale to 0, enforce bootstrap safety on galera-0 PVC, and rebuild secondaries"
      return 0  # ALLOW recovery to proceed
    fi

    if [[ "$pod_ready" != "True" ]]; then
      local recent_logs
      recent_logs=$(oc logs "$pod_0" -n "$namespace" --tail=80 2>/dev/null || echo "")
      if echo "$recent_logs" | grep -qiE "NON-PRIMARY|No nodes coming from primary view|safe_to_bootstrap"; then
        echo "   ✅ galera-0 appears to be in NON-PRIMARY/startup loop; allowing recovery to proceed"
        echo "   Recovery will reset bootstrap flow and rebuild cluster membership"
        return 0  # ALLOW recovery to proceed
      fi
    fi

    # Cluster-wide failure: multiple pods Running but MySQL unreachable on all.
    # This happens during NON-PRIMARY deadlocks where Galera refuses connections,
    # or during startup storms where MariaDB hasn't initialized yet.
    # If NO running pods are Ready, the cluster is non-functional -- allow recovery.
    if [[ "$running_count" -gt 1 ]]; then
      local ready_count=0
      for pod in $running_pods; do
        local pr
        pr=$(oc get pod "$pod" -n "$namespace" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        [[ "$pr" == "True" ]] && ready_count=$((ready_count + 1))
      done
      if [[ $ready_count -eq 0 ]]; then
        echo "   ✅ All $running_count running pods are not Ready (cluster-wide failure)"
        echo "   Recovery will: scale to 0, fix grastate.dat, rebuild from galera-0 PVC"
        return 0  # ALLOW recovery to proceed
      fi
    fi

    echo "   Cannot verify cluster state - manual intervention may be needed"
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
#   3. Delete secondary PVCs + fix grastate.dat
#   4. Set bootstrap env vars on StatefulSet template
#   5. Scale to 1 (galera-0 bootstraps from its PVC) + wait for Ready
#   7. Set partition=1, clear bootstrap env vars (partition prevents galera-0 restart)
#   8. Scale to target_replicas + NON-PRIMARY deadlock detection
#   9. Wait for sync + remove partition + final health check
#
# Step control (env vars):
#   GALERA_FROM_STEP=7   Start from step 7 (skip 1-5)
#   GALERA_TO_STEP=7     Stop after step 7
#   GALERA_FROM_STEP=7 GALERA_TO_STEP=7   Run only step 7
#   (unset = run all steps 1-9)
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
  local pc_recovery_fallback_used="false"

  # Step control: GALERA_FROM_STEP / GALERA_TO_STEP (env vars)
  # Allows running a subset of recovery steps for debugging.
  #   GALERA_FROM_STEP=7  -> skip steps 1-6, start at 7
  #   GALERA_TO_STEP=7    -> stop after step 7
  #   GALERA_FROM_STEP=7 GALERA_TO_STEP=7  -> run only step 7
  local from_step="${GALERA_FROM_STEP:-1}"
  local to_step="${GALERA_TO_STEP:-99}"

  # Precompute cluster address (cheap, needed by multiple steps)
  local cluster_address="gcomm://"
  for i in $(seq 0 $((target_replicas - 1))); do
    [[ $i -gt 0 ]] && cluster_address="${cluster_address},"
    cluster_address="${cluster_address}${sts_name}-${i}.${sts_name}-headless"
  done

  echo ""
  echo "======================================================================="
  echo "GALERA SAFE UPGRADE: $sts_name -> $target_replicas replicas"
  if [[ "$from_step" != "1" || "$to_step" != "99" ]]; then
    echo "STEP RANGE: $from_step -> $to_step"
  fi
  echo "======================================================================="

  echo "Preparing OpenShift auth context..."
  export NAMESPACE="$namespace"
  if [[ "$(type -t galera_setup_auth)" == "function" ]]; then
    if ! galera_setup_auth; then
      echo "ABORT: unable to initialize OpenShift auth for namespace $namespace"
      return 1
    fi
  else
    echo "ABORT: galera_setup_auth helper is not available in this shell"
    return 1
  fi

  # Helper: check if a step number is in range
  _in_range() { [[ $1 -ge $from_step && $1 -le $to_step ]]; }

  # =========================================================================
  # STEP 1: Pre-flight verification
  # =========================================================================
  if _in_range 1; then
  echo "Step 1: Pre-flight verification..."
  if ! galera_verify_bootstrap_safe "$sts_name" "$namespace"; then
    echo "ABORT: galera-0 is not safe to bootstrap from"
    echo "   Manual intervention required before automated upgrade can proceed."
    return 1
  fi

  # Step 1.5: Save target replica count as annotation (for future emergency recovery)
  echo ""
  echo "Step 1.5: Saving target replica count annotation..."
  if oc annotate statefulset/"$sts_name" \
    last-known-replicas="$target_replicas" \
    --overwrite \
    -n "$namespace" &>/dev/null; then
    echo "   Saved: last-known-replicas=$target_replicas"
  else
    echo "   Warning: Could not save replica count annotation (non-critical)"
    echo "   Continuing with CSV-based source of truth for target replicas"
  fi
  fi # _in_range 1

  # =========================================================================
  # STEP 2: Scale to 0
  # =========================================================================
  if _in_range 2; then
  # Step 2: Scale to 0
  echo ""
  echo "Step 2: Scaling $sts_name to 0 replicas..."
  current_replicas=$(oc get sts/"$sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$current_replicas" != "0" ]]; then
    oc scale sts/"$sts_name" --replicas=0 -n "$namespace"
  else
    echo "   Already at 0 replicas"
  fi

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

  # Allow time for volume detachment (important if pods were stuck in Init)
  echo "   Allowing time for volume detachment..."
  sleep 10

  # Step 2.5: Clear potentially bad MARIADB_EXTRA_FLAGS (config errors can cause CrashLoopBackOff)
  echo ""
  echo "Step 2.5: Clearing MARIADB_EXTRA_FLAGS (will re-apply correct settings after bootstrap)..."
  local existing_flags
  existing_flags=$(oc get statefulset/"$sts_name" -n "$namespace" \
    -o jsonpath='{.spec.template.spec.containers[?(@.name=="'"$sts_name"'")].env[?(@.name=="MARIADB_EXTRA_FLAGS")].value}' 2>/dev/null)

  if [[ -n "$existing_flags" ]]; then
    echo "   Current: MARIADB_EXTRA_FLAGS=$existing_flags"
    if oc set env statefulset/"$sts_name" MARIADB_EXTRA_FLAGS- -n "$namespace"; then
      echo "   ✅ Cleared MARIADB_EXTRA_FLAGS for clean bootstrap"
    else
      echo "   ⚠️  Failed to clear MARIADB_EXTRA_FLAGS (non-critical)"
    fi
  else
    echo "   No MARIADB_EXTRA_FLAGS to clear"
  fi
  fi # _in_range 2

  # =========================================================================
  # STEP 3: Delete secondary PVCs + fix grastate
  # =========================================================================
  if _in_range 3; then
  # Step 3: Delete secondary PVCs
  echo ""
  echo "Step 3: Deleting secondary PVCs..."
  galera_delete_secondary_pvcs "$sts_name" "$target_replicas" "$namespace"

  # Step 3.5: Force safe_to_bootstrap=1 on galera-0 PVC (defensive)
  echo ""
  echo "Step 3.5: Ensuring safe_to_bootstrap=1 on galera-0 PVC..."

  # Check if galera-0 PVC exists
  if oc get pvc "data-${sts_name}-0" -n "$namespace" &>/dev/null; then
    # Create temporary pod to edit grastate.dat
    local fixer_pod="galera-bootstrap-fixer"

    # Clean up any existing fixer pod
    oc delete pod "$fixer_pod" -n "$namespace" &>/dev/null || true

    # Create fixer pod with galera-0 PVC mounted
    cat <<EOF | oc apply -f - > /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $fixer_pod
  namespace: $namespace
spec:
  containers:
  - name: fixer
    image: busybox
    command: ['sh', '-c', 'sleep 600']
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-${sts_name}-0
  restartPolicy: Never
EOF

    # Wait for fixer pod to be ready
    local fixer_wait=0
    while [[ $fixer_wait -lt 60 ]]; do
      local fixer_ready
      fixer_ready=$(oc get pod "$fixer_pod" -n "$namespace" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      if [[ "$fixer_ready" == "True" ]]; then
        break
      fi
      sleep 2
      fixer_wait=$((fixer_wait + 2))
    done

    if [[ $fixer_wait -ge 60 ]]; then
      echo "   Warning: fixer pod not ready within 60s, attempting fix anyway..."
    fi

    # Check if grastate.dat exists
    if oc exec "$fixer_pod" -n "$namespace" -- test -f /data/data/grastate.dat 2>/dev/null; then
      # Show current value
      local current_safe
      current_safe=$(oc exec "$fixer_pod" -n "$namespace" -- \
        grep "^safe_to_bootstrap:" /data/data/grastate.dat 2>/dev/null | awk '{print $2}' || echo "unknown")
      echo "   Current safe_to_bootstrap: $current_safe"

      # Set safe_to_bootstrap=1
      oc exec "$fixer_pod" -n "$namespace" -- \
        sh -c "sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /data/data/grastate.dat" 2>/dev/null || {
        echo "   Warning: Could not modify grastate.dat (relying on FORCE_SAFETOBOOTSTRAP env var)"
      }

      # Verify the change
      local new_safe
      new_safe=$(oc exec "$fixer_pod" -n "$namespace" -- \
        grep "^safe_to_bootstrap:" /data/data/grastate.dat 2>/dev/null | awk '{print $2}' || echo "unknown")

      if [[ "$new_safe" == "1" ]]; then
        echo "   [OK] safe_to_bootstrap set to 1"
      else
        echo "   [WARN] safe_to_bootstrap is $new_safe (expected 1)"
      fi
    else
      echo "   No grastate.dat found (fresh PVC - will bootstrap with empty data)"
    fi

    # Cleanup fixer pod
    oc delete pod "$fixer_pod" -n "$namespace" &>/dev/null || true
  else
    echo "   No PVC found for galera-0 (fresh install)"
  fi
  fi # _in_range 3

  # =========================================================================
  # STEP 4: Enable bootstrap env vars + relax probes for recovery
  # =========================================================================
  if _in_range 4; then
  # Step 4: Enable bootstrap on galera-0
  echo ""
  echo "Step 4: Enabling bootstrap mode on StatefulSet template..."
  oc set env statefulset/"$sts_name" \
    "MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes" \
    "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes" \
    "MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://" \
    -n "$namespace"

  # Step 4.5: Relax probe timeouts for recovery
  # During bootstrap/IST/SST, MariaDB is under heavy I/O and wsrep queries can be slow.
  # Default 1s timeouts cause probe failures → CrashLoopBackoff mid-sync.
  # Values aligned with Helm --set flags in deploy-mariadb-galera.sh:
  #   - startupProbe:   5s timeout, 15s period, 80 failures = ~22min window
  #   - readinessProbe: 5s timeout, 15s period
  #   - livenessProbe:  10s timeout, 30s period, 6 failures, 180s init = ~6min kill window
  # All probes use mysqladmin status (safer than wsrep query during IST)
  echo ""
  echo "Step 4.5: Relaxing probe timeouts for recovery (prevents CrashLoopBackoff during sync)..."
  local probe_patch
  probe_patch=$(cat <<'PROBEPATCH'
{
  "spec": {
    "template": {
      "spec": {
        "containers": [{
          "name": "mariadb-galera",
          "startupProbe": {
            "exec": {
              "command": ["bash", "-ec", "password_aux=\"${MARIADB_ROOT_PASSWORD:-}\"\nif [[ -f \"${MARIADB_ROOT_PASSWORD_FILE:-}\" ]]; then\n    password_aux=$(cat \"$MARIADB_ROOT_PASSWORD_FILE\")\nfi\nexec mysqladmin status -u\"${MARIADB_ROOT_USER}\" -p\"${password_aux}\"\n"]
            },
            "initialDelaySeconds": 120,
            "periodSeconds": 15,
            "timeoutSeconds": 5,
            "failureThreshold": 80,
            "successThreshold": 1
          },
          "livenessProbe": {
            "exec": {
              "command": ["bash", "-ec", "password_aux=\"${MARIADB_ROOT_PASSWORD:-}\"\nif [[ -f \"${MARIADB_ROOT_PASSWORD_FILE:-}\" ]]; then\n    password_aux=$(cat \"$MARIADB_ROOT_PASSWORD_FILE\")\nfi\nexec mysqladmin status -u\"${MARIADB_ROOT_USER}\" -p\"${password_aux}\"\n"]
            },
            "initialDelaySeconds": 180,
            "periodSeconds": 30,
            "timeoutSeconds": 10,
            "failureThreshold": 6,
            "successThreshold": 1
          },
          "readinessProbe": {
            "exec": {
              "command": ["bash", "-ec", "password_aux=\"${MARIADB_ROOT_PASSWORD:-}\"\nif [[ -f \"${MARIADB_ROOT_PASSWORD_FILE:-}\" ]]; then\n    password_aux=$(cat \"$MARIADB_ROOT_PASSWORD_FILE\")\nfi\nexec mysqladmin status -u\"${MARIADB_ROOT_USER}\" -p\"${password_aux}\"\n"]
            },
            "initialDelaySeconds": 30,
            "periodSeconds": 15,
            "timeoutSeconds": 5,
            "failureThreshold": 3,
            "successThreshold": 1
          }
        }]
      }
    }
  }
}
PROBEPATCH
)
  if oc patch statefulset/"$sts_name" -n "$namespace" --type=strategic -p "$probe_patch" 2>/dev/null; then
    echo "   ✅ Probe timeouts: startup=5s/15s/80fail  readiness=5s/15s  liveness=10s/30s/6fail/180s-init"
    echo "   ✅ All probes use mysqladmin status (safer than wsrep query during IST)"
  else
    echo "   ⚠️  Probe patch failed (non-fatal, using existing probe settings)"
  fi
  fi # _in_range 4

  # =========================================================================
  # STEP 5-6: Scale to 1 + wait for galera-0 Ready
  # =========================================================================
  if _in_range 5; then
  # Step 5: Scale to 1 (galera-0 bootstraps)
  echo ""
  echo "Step 5: Scaling to 1 replica (galera-0 bootstrap)..."
  current_replicas=$(oc get sts/"$sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  if [[ "$current_replicas" != "1" ]]; then
    oc scale sts/"$sts_name" --replicas=1 -n "$namespace"
  else
    echo "   Already at 1 replica"
  fi

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

    # Conditional fallback for stale primary component recovery state.
    # Only apply during single-node recovery when logs indicate NON-PRIMARY loop.
    local running_pods
    running_pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    local running_count
    running_count=$(wc -w <<< "$running_pods" | tr -d ' ')
    local recent_logs
    recent_logs=$(oc logs "${sts_name}-0" -n "$namespace" --tail=200 2>/dev/null || echo "")

    if [[ "$running_count" == "1" && "$running_pods" == "${sts_name}-0" ]] \
      && echo "$recent_logs" | grep -qiE "NON-PRIMARY|No nodes coming from primary view|restore pc from disk"; then
      echo ""
      echo "================================================================================"
      echo "[FALLBACK] Detected single-node NON-PRIMARY loop; applying pc.recovery reset"
      echo "================================================================================"
      pc_recovery_fallback_used="true"
      send_notification "GALERA_PC_RECOVERY_FALLBACK" "Galera PC Recovery Fallback" "Bootstrap timeout with NON-PRIMARY loop detected. Applying one-shot pc.recovery=FALSE fallback for statefulset/$sts_name in $namespace" "warning" "$namespace"

      local fallback_flags
      fallback_flags="--wsrep-provider-options=pc.recovery=FALSE;evs.suspect_timeout=PT30S;evs.inactive_timeout=PT30S;evs.install_timeout=PT30S;evs.delayed_keep_period=PT30S"
      if oc set env statefulset/"$sts_name" MARIADB_EXTRA_FLAGS="$fallback_flags" -n "$namespace" >/dev/null; then
        echo "   [ACTION] Applied: pc.recovery=FALSE + PT30S timeouts"
      else
        echo "   [WARN] Failed to apply temporary fallback flags; continuing anyway"
      fi

      echo "   [ACTION] Clearing stale primary component state files from PVC-0"
      local fixer_pod="galera-pc-reset-fixer"
      oc delete pod "$fixer_pod" -n "$namespace" &>/dev/null || true
      cat <<EOF | oc apply -f - > /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: $fixer_pod
  namespace: $namespace
spec:
  containers:
  - name: fixer
    image: busybox
    command: ['sh', '-c', 'sleep 600']
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-${sts_name}-0
  restartPolicy: Never
EOF

      local fixer_wait=0
      while [[ $fixer_wait -lt 60 ]]; do
        local fixer_ready
        fixer_ready=$(oc get pod "$fixer_pod" -n "$namespace" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        [[ "$fixer_ready" == "True" ]] && break
        sleep 2
        fixer_wait=$((fixer_wait + 2))
      done

      oc exec "$fixer_pod" -n "$namespace" -- sh -c "rm -f /data/data/gvwstate.dat /data/data/grastate.dat.recover 2>/dev/null || true" >/dev/null 2>&1 || true
      oc delete pod "$fixer_pod" -n "$namespace" &>/dev/null || true
      echo "   [OK] Stale files cleared"

      echo "   [ACTION] Retrying bootstrap (0 -> 1) with fallback settings"
      oc scale sts/"$sts_name" --replicas=0 -n "$namespace" >/dev/null || true
      sleep 10
      oc scale sts/"$sts_name" --replicas=1 -n "$namespace" >/dev/null || true

      local fallback_wait=0
      while [[ $fallback_wait -lt 600 ]]; do
        local fallback_ready
        fallback_ready=$(oc get pod "${sts_name}-0" -n "$namespace" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$fallback_ready" == "True" ]]; then
          echo "   [OK] Fallback retry succeeded: ${sts_name}-0 is Ready"
          send_notification "GALERA_PC_RECOVERY_FALLBACK_SUCCESS" "Galera PC Recovery Fallback Succeeded" "Successfully recovered statefulset/$sts_name from NON-PRIMARY loop using pc.recovery=FALSE fallback" "success" "$namespace"
          break
        fi
        sleep 10
        fallback_wait=$((fallback_wait + 10))
        if [[ $((fallback_wait % 60)) -eq 0 ]]; then
          echo "   [WAIT] Fallback retry in progress... ${fallback_wait}s elapsed"
        fi
      done

      if [[ $fallback_wait -ge 600 ]]; then
        echo "   [ERROR] Fallback bootstrap failed after 600s"
        send_notification "GALERA_PC_RECOVERY_FALLBACK_FAILED" "Galera PC Recovery Fallback Failed" "PC recovery fallback for statefulset/$sts_name exhausted. Manual intervention required." "error" "$namespace"
        oc set env statefulset/"$sts_name" \
          "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
          "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
          "MARIADB_GALERA_CLUSTER_ADDRESS-" \
          MARIADB_EXTRA_FLAGS- \
          -n "$namespace" 2>/dev/null || true
        return 1
      fi
    else
      # Restore safe state before returning failure
      oc set env statefulset/"$sts_name" \
        "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
        "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
        "MARIADB_GALERA_CLUSTER_ADDRESS-" \
        -n "$namespace" 2>/dev/null || true
      return 1
    fi
  fi
  fi # _in_range 5

  # =========================================================================
  # STEP 7: Set partition, disable bootstrap, verify galera-0 Primary
  # Precondition: galera-0 is Running and Primary (from Step 6)
  # =========================================================================
  if _in_range 7; then
  # Step 7: Disable bootstrap and restore cluster address (so secondaries join, not bootstrap)
  #
  # CRITICAL DESIGN NOTE:
  # We must NOT restart galera-0 here. Changing env vars via 'oc set env' updates the
  # StatefulSet template, which triggers a rolling restart. If galera-0 restarts with
  # bootstrap=no while it's the only node, it cannot form a Primary component (no peers
  # exist yet) and enters NON-PRIMARY, deadlocking the entire cluster.
  #
  # Solution: use StatefulSet partition to BLOCK the rolling restart. galera-0 keeps
  # running with the old env (bootstrap=yes, Primary). Secondaries start with the NEW
  # template (bootstrap=no, proper cluster address) and join the running Primary on
  # galera-0. After all secondaries sync, we remove the partition so galera-0 restarts
  # with bootstrap=no and safely rejoins the cluster.
  echo ""
  echo "Step 7: Disabling bootstrap mode and restoring cluster discovery..."

  # Set partition=1 to prevent galera-0 (ordinal 0) from being restarted by the rolling update.
  # Pods with ordinal >= partition are updated; ordinal 0 < 1, so it stays untouched.
  echo "   Setting partition=1 to protect running galera-0 from rolling restart..."
  oc patch statefulset/"$sts_name" -n "$namespace" -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":1}}}}' 2>/dev/null || true

  # Generate cluster address INCLUDING all target replicas
  # Even if running at 1 replica now, all nodes need to know the full member list
  # so galera-1+ join instead of bootstrapping when scaled up later
  local cluster_address="gcomm://"
  for i in $(seq 0 $((target_replicas - 1))); do
    if [[ $i -gt 0 ]]; then
      cluster_address="${cluster_address},"
    fi
    cluster_address="${cluster_address}${sts_name}-${i}.${sts_name}-headless"
  done

  echo "   Setting cluster address: $cluster_address"
  oc set env statefulset/"$sts_name" \
    "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
    "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
    "MARIADB_GALERA_CLUSTER_ADDRESS=${cluster_address}" \
    -n "$namespace"

  # Wait for StatefulSet spec update to propagate
  sleep 3

  # Verify bootstrap env vars were actually cleared (defensive)
  local actual_bootstrap
  actual_bootstrap=$(oc get statefulset/"$sts_name" -n "$namespace" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MARIADB_GALERA_CLUSTER_BOOTSTRAP")].value}' 2>/dev/null)
  if [[ "$actual_bootstrap" == "yes" ]]; then
    echo "   WARNING: MARIADB_GALERA_CLUSTER_BOOTSTRAP still 'yes' in spec - retrying..."
    oc set env statefulset/"$sts_name" \
      "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
      "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
      -n "$namespace"
    sleep 2
  fi
  echo "   MARIADB_GALERA_CLUSTER_BOOTSTRAP=$(oc get statefulset/"$sts_name" -n "$namespace" \
    -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MARIADB_GALERA_CLUSTER_BOOTSTRAP")].value}' 2>/dev/null)"

  # Step 7.5: Verify cluster address was set correctly (defensive check)
  echo ""
  echo "Step 7.5: Verifying cluster address configuration..."
  galera_verify_cluster_address "$sts_name" "$namespace" "fix" "$target_replicas"

  # Step 7.6a: Clean up any leftover MARIADB_EXTRA_FLAGS from prior recovery attempts.
  # NOTE: DO NOT set --wsrep-provider-options via MARIADB_EXTRA_FLAGS — it REPLACES the
  # entire provider options string (gcache, gcomm, base_host, etc.), causing segfaults
  # on SST. Galera timeout tuning must be done via my.cnf or Helm values instead.
  echo ""
  echo "Step 7.6a: Cleaning up any leftover MARIADB_EXTRA_FLAGS..."
  if oc set env statefulset/"$sts_name" MARIADB_EXTRA_FLAGS- -n "$namespace" 2>/dev/null; then
    echo "   Cleared MARIADB_EXTRA_FLAGS from template (if present)"
  fi

  # Verify galera-0 is still Primary (partition kept it running untouched)
  echo ""
  echo "Step 7.6: Verifying galera-0 is still Primary (partition-protected)..."
  local g0_status
  g0_status=$(oc exec "${sts_name}-0" -n "$namespace" -- \
    mysql -u root -p"${DB_PASSWORD}" \
    -Nse "SHOW STATUS LIKE 'wsrep_cluster_status';" 2>/dev/null \
    | awk '{print $2}' || echo "unknown")
  local g0_state
  g0_state=$(oc exec "${sts_name}-0" -n "$namespace" -- \
    mysql -u root -p"${DB_PASSWORD}" \
    -Nse "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null \
    | awk '{print $2}' || echo "unknown")

  if [[ "$g0_status" == "Primary" ]]; then
    echo "   ✅ galera-0 is Primary/$g0_state (partition held, no restart)"
  else
    echo "   ⚠️  galera-0 status: $g0_status/$g0_state"
    echo "   This may indicate the pod was restarted externally."
    echo "   Proceeding with scale-out -- secondaries may still resolve the cluster."
  fi

  # Note: MARIADB_EXTRA_FLAGS was already cleaned up in Step 7.6a.
  # Any pc.recovery fallback flags were removed at that point.
  fi # _in_range 7

  # =========================================================================
  # STEP 8: Scale to target replicas + NON-PRIMARY deadlock detection
  # Precondition: galera-0 is Primary, template has bootstrap=no + cluster_address
  # =========================================================================
  if _in_range 8; then
  # Step 8: Scale to target (if > 1)
  if [[ "$target_replicas" -gt 1 ]]; then
    echo ""
    echo "Step 8: Scaling to $target_replicas replicas..."
    current_replicas=$(oc get sts/"$sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [[ "$current_replicas" != "$target_replicas" ]]; then
      oc scale sts/"$sts_name" --replicas="$target_replicas" -n "$namespace"
    else
      echo "   Already at $target_replicas replicas"
    fi

    # Step 8.5: Detect NON-PRIMARY deadlock after scale-out and perform one-shot rebootstrap.
    # This handles the case where all nodes start with bootstrap=no and no primary component can form.
    echo ""
    echo "Step 8.5: Checking for NON-PRIMARY deadlock before sync wait..."
    local deadlock_detected="false"
    local wsrep_cluster_status_after_scale
    local wsrep_local_state_after_scale
    local wsrep_connected_after_scale
    local recent_primary_logs
    local rebootstrap_used="false"

    # Give the first startup wave a short window before evaluating cluster state.
    sleep 20

    wsrep_cluster_status_after_scale=$(oc exec "${sts_name}-0" -n "$namespace" -- \
      mysql -u root -p"${DB_PASSWORD}" -Nse "SHOW STATUS LIKE 'wsrep_cluster_status';" 2>/dev/null \
      | awk '{print $2}' || echo "unknown")
    wsrep_local_state_after_scale=$(oc exec "${sts_name}-0" -n "$namespace" -- \
      mysql -u root -p"${DB_PASSWORD}" -Nse "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null \
      | awk '{print $2}' || echo "unknown")
    wsrep_connected_after_scale=$(oc exec "${sts_name}-0" -n "$namespace" -- \
      mysql -u root -p"${DB_PASSWORD}" -Nse "SHOW STATUS LIKE 'wsrep_connected';" 2>/dev/null \
      | awk '{print $2}' || echo "unknown")

    recent_primary_logs=$(oc logs "${sts_name}-0" -n "$namespace" --tail=250 2>/dev/null || true)

    if [[ "$wsrep_cluster_status_after_scale" != "Primary" ]] \
      || echo "$recent_primary_logs" | grep -qiE "No nodes coming from primary view|Received NON-PRIMARY|view\(view_id\(NON_PRIM"; then
      deadlock_detected="true"
    fi

    if [[ "$deadlock_detected" == "true" ]]; then
      echo "   [WARN] Detected NON-PRIMARY deadlock after scale-out"
      echo "   [INFO] wsrep_connected=$wsrep_connected_after_scale, cluster_status=$wsrep_cluster_status_after_scale, local_state=$wsrep_local_state_after_scale"
      send_notification "GALERA_NON_PRIMARY_DEADLOCK" "Galera NON-PRIMARY Deadlock" "Detected NON-PRIMARY deadlock after scale-out for statefulset/$sts_name. Running one-shot rebootstrap from pod-0." "warning" "$namespace"

      # Remove partition before rebootstrap -- Kubernetes recreates partitioned pods at
      # the old template revision, which would prevent the bootstrap=yes env from taking effect.
      echo "   [ACTION] Removing partition for rebootstrap..."
      oc patch statefulset/"$sts_name" -n "$namespace" -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}' 2>/dev/null || true

      echo "   [ACTION] Enabling temporary bootstrap mode for one-shot rebootstrap"
      oc set env statefulset/"$sts_name" \
        "MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes" \
        "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes" \
        "MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://" \
        -n "$namespace" >/dev/null || true

      echo "   [ACTION] Rebootstrapping primary (0 -> 1)"
      oc scale sts/"$sts_name" --replicas=0 -n "$namespace" >/dev/null || true
      sleep 10
      oc scale sts/"$sts_name" --replicas=1 -n "$namespace" >/dev/null || true

      local rebootstrap_wait=0
      while [[ $rebootstrap_wait -lt 600 ]]; do
        local rebootstrap_ready
        rebootstrap_ready=$(oc get pod "${sts_name}-0" -n "$namespace" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$rebootstrap_ready" == "True" ]]; then
          break
        fi
        sleep 10
        rebootstrap_wait=$((rebootstrap_wait + 10))
      done

      if [[ $rebootstrap_wait -ge 600 ]]; then
        echo "   [ERROR] Rebootstrap failed: ${sts_name}-0 did not become Ready"
        send_notification "GALERA_NON_PRIMARY_REBOOTSTRAP_FAILED" "Galera Rebootstrap Failed" "One-shot rebootstrap for statefulset/$sts_name failed (pod-0 not Ready within timeout)." "error" "$namespace"
        return 1
      fi

      wsrep_cluster_status_after_scale=$(oc exec "${sts_name}-0" -n "$namespace" -- \
        mysql -u root -p"${DB_PASSWORD}" -Nse "SHOW STATUS LIKE 'wsrep_cluster_status';" 2>/dev/null \
        | awk '{print $2}' || echo "unknown")
      wsrep_local_state_after_scale=$(oc exec "${sts_name}-0" -n "$namespace" -- \
        mysql -u root -p"${DB_PASSWORD}" -Nse "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null \
        | awk '{print $2}' || echo "unknown")

      if [[ "$wsrep_cluster_status_after_scale" != "Primary" ]]; then
        echo "   [ERROR] Rebootstrap failed: pod-0 is not in Primary state (status=$wsrep_cluster_status_after_scale)"
        send_notification "GALERA_NON_PRIMARY_REBOOTSTRAP_FAILED" "Galera Rebootstrap Failed" "One-shot rebootstrap completed but pod-0 is not Primary (status=$wsrep_cluster_status_after_scale)." "error" "$namespace"
        return 1
      fi

      echo "   [OK] One-shot rebootstrap succeeded: pod-0 is Primary/$wsrep_local_state_after_scale"
      send_notification "GALERA_NON_PRIMARY_REBOOTSTRAP_SUCCESS" "Galera Rebootstrap Succeeded" "Recovered from NON-PRIMARY deadlock using one-shot rebootstrap for statefulset/$sts_name." "success" "$namespace"
      rebootstrap_used="true"

      echo "   [ACTION] Restoring non-bootstrap discovery configuration and scaling to target"
      oc set env statefulset/"$sts_name" \
        "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
        "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
        "MARIADB_GALERA_CLUSTER_ADDRESS=${cluster_address}" \
        -n "$namespace" >/dev/null || true
      oc scale sts/"$sts_name" --replicas="$target_replicas" -n "$namespace" >/dev/null || true
    else
      echo "   [OK] No NON-PRIMARY deadlock detected"
    fi
  fi # target_replicas > 1 (step 8 outer guard)
  fi # _in_range 8

  # =========================================================================
  # STEP 9: Wait for sync + partition removal + final health
  # Precondition: all pods running, galera-0 still partitioned (old template)
  # =========================================================================
  if _in_range 9; then
  if [[ "$target_replicas" -gt 1 ]]; then
    # Step 9: Wait for sync
    echo ""
    echo "Step 9: Waiting for Galera cluster synchronization..."
    if ! wait_for_galera_sync "$sts_name" 120 10 "$target_replicas"; then
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

    # Step 9.5: Remove partition to let galera-0 restart with the updated template.
    # Now that pods 1-N are Primary/Synced, galera-0 can safely restart with bootstrap=no
    # and rejoin the cluster through its peers.
    #
    # CRITICAL: Wait for galera-0 to finish any SST donations (DONOR state) before
    # removing the partition. Killing galera-0 mid-SST corrupts the joiner and
    # cascades into CrashLoopBackOff for the entire cluster.
    echo ""
    echo "Step 9.5: Preparing partition removal (waiting for galera-0 to finish SST donations)..."
    local donor_wait=0
    while [[ $donor_wait -lt 300 ]]; do
      local g0_wsrep_state
      g0_wsrep_state=$(oc exec "${sts_name}-0" -n "$namespace" -- \
        mysql -u root -p"${DB_PASSWORD}" \
        -Nse "SHOW STATUS LIKE 'wsrep_local_state_comment';" 2>/dev/null \
        | awk '{print $2}' || echo "unknown")
      if [[ "$g0_wsrep_state" == "Synced" ]]; then
        echo "   ✅ galera-0 is Synced (not DONOR), safe to restart"
        break
      fi
      if [[ $donor_wait -eq 0 ]]; then
        echo "   galera-0 state: $g0_wsrep_state (waiting for Synced before restart)..."
      fi
      sleep 10
      donor_wait=$((donor_wait + 10))
      if [[ $((donor_wait % 60)) -eq 0 ]]; then
        echo "   galera-0 state: $g0_wsrep_state (${donor_wait}s elapsed)..."
      fi
    done
    if [[ $donor_wait -ge 300 ]]; then
      echo "   ⚠️  galera-0 still not Synced after 300s (state: $g0_wsrep_state)"
      echo "   Proceeding with partition removal anyway -- cluster has $((target_replicas - 1)) healthy nodes"
    fi

    echo "   Removing partition -- galera-0 will restart with non-bootstrap config..."
    oc patch statefulset/"$sts_name" -n "$namespace" -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}' 2>/dev/null || true

    # Wait for galera-0 to be replaced by the rolling update and become Ready
    echo "   Waiting for ${sts_name}-0 to restart and rejoin cluster..."
    local partition_wait=0
    while [[ $partition_wait -lt 600 ]]; do
      local g0_ready
      g0_ready=$(oc get pod "${sts_name}-0" -n "$namespace" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
      local g0_gen
      g0_gen=$(oc get pod "${sts_name}-0" -n "$namespace" \
        -o jsonpath='{.metadata.labels.controller-revision-hash}' 2>/dev/null || echo "")
      local sts_gen
      sts_gen=$(oc get statefulset/"$sts_name" -n "$namespace" \
        -o jsonpath='{.status.updateRevision}' 2>/dev/null || echo "")

      if [[ "$g0_ready" == "True" && "$g0_gen" == "$sts_gen" ]]; then
        echo "   ✅ ${sts_name}-0 restarted and Ready (revision: $g0_gen)"
        break
      fi
      sleep 10
      partition_wait=$((partition_wait + 10))
      if [[ $((partition_wait % 60)) -eq 0 ]]; then
        echo "   Still waiting for ${sts_name}-0... ${partition_wait}s elapsed (ready=$g0_ready, rev=$g0_gen, target=$sts_gen)"
      fi
    done

    if [[ $partition_wait -ge 600 ]]; then
      echo "   ⚠️  ${sts_name}-0 did not become Ready within 600s after partition removal"
      echo "   Cluster may still be functional via pods 1-$((target_replicas - 1))"
      echo "   Check: oc get pods -l app.kubernetes.io/name=$sts_name -n $namespace"
      # Don't return failure -- the cluster is operational with the other nodes
    fi

    # Final cluster-wide health check after galera-0 rejoin
    echo ""
    echo "Step 9.6: Final cluster health verification..."
    check_galera_cluster_health "$selector" "$namespace" "$target_replicas"
    local final_health=$?
    if [[ $final_health -ne 0 ]]; then
      echo "   ⚠️  Post-rejoin health check returned code $final_health (cluster may still be stabilizing)"
    else
      echo "   ✅ All $target_replicas nodes healthy"
    fi
  else
    echo ""
    echo "Single-replica cluster -- skipping sync verification"
  fi
  fi # _in_range 9

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

# =============================================================================
# GALERA EMERGENCY RECOVERY WRAPPER
# =============================================================================
# Determines target replica count from right-sizing CSV → annotation → defaults
# Then executes galera_safe_upgrade with detected replica count
# =============================================================================

galera_emergency_recovery() {
  local sts_name="${1:-mariadb-galera}"
  local target_replicas="${2:-0}"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  echo ""
  echo "======================================================================="
  echo "GALERA EMERGENCY RECOVERY: $sts_name"
  echo "======================================================================="

  # If target explicitly provided, use it
  if [[ "$target_replicas" -gt 0 ]]; then
    echo "Target replica count: $target_replicas (specified)"
  else
    # Detect from CSV, annotation, or defaults
    echo "Detecting target replica count..."

    # Try right-sizing CSV first (primary source of truth)
    local csv_file="/openshift/${namespace}-sizing.csv"
    local csv_replicas=""

    if [[ -f "$csv_file" ]]; then
      # Parse CSV for mariadb-galera Pod Count
      csv_replicas=$(awk -F',' '$1 == "mariadb-galera" {print $3}' "$csv_file" | tr -d ' ')
      if [[ -n "$csv_replicas" && "$csv_replicas" =~ ^[0-9]+$ ]]; then
        echo "   Right-sizing CSV: $csv_replicas replicas ($csv_file)"
        target_replicas="$csv_replicas"
      else
        echo "   Warning: Could not parse replica count from CSV"
      fi
    else
      echo "   Warning: Right-sizing CSV not found: $csv_file"
    fi

    # Try annotation as secondary source
    if [[ "$target_replicas" -eq 0 ]]; then
      local annotation
      annotation=$(oc get statefulset "$sts_name" -n "$namespace" \
        -o jsonpath='{.metadata.annotations.last-known-replicas}' 2>/dev/null)

      if [[ -n "$annotation" && "$annotation" =~ ^[0-9]+$ && "$annotation" -gt 0 ]]; then
        echo "   Last-known annotation: $annotation replicas"
        target_replicas="$annotation"
      fi
    fi

    # Final fallback - environment defaults
    if [[ "$target_replicas" -eq 0 ]]; then
      case "$namespace" in
        950003-prod)
          target_replicas=5
          ;;
        950003-test|950003-dev)
          target_replicas=2
          ;;
        *)
          target_replicas=2
          ;;
      esac
      echo "   Environment default: $target_replicas replicas"
    fi
  fi

  echo ""
  echo "Will recover to: $target_replicas replicas"
  echo ""

  # Execute galera_safe_upgrade with determined replica count
  galera_safe_upgrade "$sts_name" "$target_replicas" "$namespace"
  return $?
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
