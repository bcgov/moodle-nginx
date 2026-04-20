#!/bin/bash
# Force UTF-8 locale so emoji/unicode in arrays render correctly in pod logs
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# =============================================================================
# CONTINUOUS POD HEALTH MONITOR
# =============================================================================
# Purpose: Lightweight continuous monitoring wrapper for pod health checks
#          Runs as a long-lived deployment instead of CronJob
#
# Architecture:
#   - Runs in loop with configurable intervals
#   - Calls check-pod-logs.sh utility functions for actual health checks
#   - Tracks consecutive errors per pod for intelligent restart logic
#   - Special handling for Galera cluster with separate check interval
#
# Deployment:
#   - Via pod-health-monitor.yml template
#   - Requires same service account permissions as check-pod-logs.sh
#   - Automatically deployed by ./deploy-health-monitor.sh
#
# Configuration:
#   MONITORING_INTERVAL=60      - Seconds between quick health checks
#   GALERA_CHECK_INTERVAL=300   - Seconds between comprehensive Galera checks
#   ERROR_THRESHOLD=3           - Consecutive errors before pod restart
#
# Related Documentation:
#   - Core health checks: ./check-pod-logs.sh (comprehensive monitoring logic)
#   - Deployment guide: ./deploy-health-monitor.sh
#   - Architecture: ../../docs/galera-monitoring-solution.md
# =============================================================================

# Configuration
MONITORING_INTERVAL=${MONITORING_INTERVAL:-60}
GALERA_CHECK_INTERVAL=${GALERA_CHECK_INTERVAL:-300}  # Check Galera every 5 minutes
ERROR_THRESHOLD=${ERROR_THRESHOLD:-3}  # Number of consecutive errors before restart
MANUAL_MODE=${MANUAL_MODE:-false}  # Override flag - set to 'true' to disable all auto-healing
AUTO_APPLY_GALERA_TIMEOUTS=${AUTO_APPLY_GALERA_TIMEOUTS:-true}  # Auto-apply PT30S timeouts during recovery

# Track consecutive errors per pod
declare -A error_counts

# Initialize logging
echo "Starting continuous pod health monitoring..."
echo "Monitoring interval: ${MONITORING_INTERVAL}s"
echo "Galera check interval: ${GALERA_CHECK_INTERVAL}s"
echo "Error threshold: ${ERROR_THRESHOLD}"
echo "Auto-apply Galera timeouts: ${AUTO_APPLY_GALERA_TIMEOUTS}"

# Manual mode override check
if [[ "${MANUAL_MODE,,}" == "true" ]]; then
  echo ""
  echo "----------------------------------------------------------------"
  echo "MANUAL MODE ENABLED"
  echo "----------------------------------------------------------------"
  echo "All auto-healing actions are DISABLED."
  echo "Pod health monitoring is READ-ONLY - manual intervention in progress."
  echo ""
  echo "To re-enable auto-healing:"
  echo "  oc set env deployment/pod-health-monitor MANUAL_MODE=false -n $DEPLOY_NAMESPACE"
  echo ""
  echo "Galera timeout auto-apply: ${AUTO_APPLY_GALERA_TIMEOUTS}"
  echo "To control PT30S timeout configuration:"
  echo "  oc set env deployment/pod-health-monitor AUTO_APPLY_GALERA_TIMEOUTS=true|false -n $DEPLOY_NAMESPACE"
  echo "----------------------------------------------------------------"
  echo ""
fi

# Universal _utils.sh loader - works in all environments
# Priority: same-dir > /scripts > /usr/local/bin > ./openshift/scripts
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

# Validate required environment
if [[ -z "$DEPLOY_NAMESPACE" ]]; then
  echo "FATAL: DEPLOY_NAMESPACE is not set - cannot monitor pods"
  exit 1
fi

# Authenticate with OpenShift API (same as check-pod-logs.sh)
# Set writable kubeconfig path - container filesystem root is read-only
export KUBECONFIG="/tmp/.kube/config"
mkdir -p "$(dirname "$KUBECONFIG")"

# Check if running in-cluster with service account
if [[ -f "/var/run/secrets/kubernetes.io/serviceaccount/token" && -z "$OPENSHIFT_TOKEN" ]]; then
  echo "INFO: Running in-cluster with service account - configuring oc to use pod SA token"
  SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CLUSTER_SERVER="${OPENSHIFT_SERVER:-https://kubernetes.default.svc}"

  oc login --token="$SA_TOKEN" --server="$CLUSTER_SERVER" --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:"
  oc project "$DEPLOY_NAMESPACE" 2>/dev/null || true
elif [[ -n "$OPENSHIFT_TOKEN" && -n "$OPENSHIFT_SERVER" ]]; then
  echo "INFO: Using provided OPENSHIFT_TOKEN for authentication"
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:"
  oc project "$DEPLOY_NAMESPACE" 2>/dev/null || true
else
  echo "WARNING: Neither in-cluster SA token nor OPENSHIFT_TOKEN found - oc commands may fail"
fi

# Validate oc connectivity - fail fast if API is unreachable
if ! oc get namespace "$DEPLOY_NAMESPACE" -o name &>/dev/null; then
  echo "FATAL: Cannot reach OpenShift API or namespace $DEPLOY_NAMESPACE - check credentials"
  exit 1
fi
echo "[OK] OpenShift API connectivity verified for namespace: $DEPLOY_NAMESPACE"

# Suppress repetitive oc CLI warnings (legacy token, insecure TLS) from polluting health check logs
export KUBECTL_WARN_EXTERNAL_UNKNOWN=false
oc() { command oc "$@" 2> >(grep -v "^Warning:" >&2); }

# Unified pod health check function
# $1: selector  $2: error_patterns  $3: restart_enabled (true/false)
# Appends to global issue_details[] array, increments pods_checked counter,
# and appends to service_summary[] for per-service visibility.
check_pod_health() {
  local selector="$1"
  local error_patterns="$2"
  local restart_enabled="${3:-false}"

  local pods_output
  pods_output=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>&1)
  local oc_exit=$?
  local pod_count=0
  local mode_label="observe"
  [[ "$restart_enabled" == "true" ]] && mode_label="restart"

  # Distinguish "no pods" from "oc comm failed" (auth expired, network, etc.)
  if [[ $oc_exit -ne 0 ]]; then
    service_summary+=("  [WARN] $selector - oc query failed (exit $oc_exit) [$mode_label]")
    issue_details+=("  [WARN] oc get pods -l $selector failed - possible API connectivity issue")
    return 1
  fi

  local pods="$pods_output"
  if [[ -z "$pods" ]]; then
    service_summary+=("  [INFO] $selector - no running pods [$mode_label]")
    return 0
  fi

  local issues_found=0

  for pod in $pods; do
    pod_count=$((pod_count + 1))
    local recent_logs=$(oc logs "$pod" --tail=10 2>/dev/null)

    if [[ -z "$recent_logs" ]]; then
      pods_checked=$((pods_checked + 1))
      continue
    fi

    IFS=',' read -ra patterns <<< "$error_patterns"
    local pod_has_errors=false

    for pattern in "${patterns[@]}"; do
      pattern=$(echo "$pattern" | xargs)
      if [[ -n "$pattern" && "$recent_logs" == *"$pattern"* ]]; then
        error_counts["$pod"]=$((${error_counts["$pod"]:-0} + 1))
        pod_has_errors=true

        local consecutive=${error_counts["$pod"]}
        local mode="observe"
        [[ "$restart_enabled" == "true" ]] && mode="restart-eligible"

        issue_details+=("  [WARN] $pod [$mode] - pattern '$pattern' (consecutive: $consecutive/$ERROR_THRESHOLD)")
        break
      fi
    done

    if [[ "$pod_has_errors" == "false" ]]; then
      error_counts["$pod"]=0
    fi

    pods_checked=$((pods_checked + 1))

    # Restart only for restart-eligible pods at error threshold
    if [[ "$restart_enabled" == "true" && ${error_counts["$pod"]:-0} -ge $ERROR_THRESHOLD ]]; then
      if [[ "${MANUAL_MODE,,}" == "true" ]]; then
        issue_details+=("  - [MANUAL MODE] Would restart $pod - $ERROR_THRESHOLD consecutive errors (auto-healing disabled)")
        continue
      fi
      issue_details+=("  [ACTION] RESTARTING $pod - $ERROR_THRESHOLD consecutive errors reached")

      if oc delete pod "$pod" --wait=false; then
        send_notification "POD_RESTART_THRESHOLD" "Pod Restarted - Error Threshold" "Pod $pod restarted after $ERROR_THRESHOLD consecutive errors. Selector: $selector" "warning" "$DEPLOY_NAMESPACE"
        error_counts["$pod"]=0
        issues_found=$((issues_found + 1))

        # Post-restart verification - wait briefly, then check if replacement pod starts
        issue_details+=("  [WAIT] Waiting 15s for replacement pod...")
        sleep 15
        local new_pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -n "$new_pods" ]]; then
          issue_details+=("  [OK] Replacement pod(s) running: $new_pods")
        else
          local pending_pods=$(oc get pods -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null)
          issue_details+=("  [ERROR] No running replacement yet - pod status: ${pending_pods:-unknown}")
          issue_details+=("     Check: oc get pods -l $selector -n $DEPLOY_NAMESPACE")
        fi
      else
        issue_details+=("  - Failed to delete $pod - oc delete returned non-zero")
        issue_details+=("     Check: oc describe pod $pod -n $DEPLOY_NAMESPACE")
      fi
    fi
  done

  # Per-service summary line for visibility
  if [[ $issues_found -gt 0 ]]; then
    service_summary+=("  [ALERT] $selector - $pod_count pod(s), $issues_found issue(s) [$mode_label]")
  else
    service_summary+=("  [OK] $selector - $pod_count pod(s) healthy [$mode_label]")
  fi

  return $issues_found
}

# Main monitoring loop
last_galera_check=0
last_status_report=0
check_cycle=0
STATUS_REPORT_INTERVAL=${STATUS_REPORT_INTERVAL:-600}  # Status summary every 10 minutes

# Send startup notification
send_notification "MONITORING_START" "Pod Health Monitor Started" "Continuous monitoring active with ${MONITORING_INTERVAL}s intervals. Galera checks every ${GALERA_CHECK_INTERVAL}s." "white_check_mark" "$DEPLOY_NAMESPACE"

while true; do
  current_time=$(date +%s)

  # Deployments eligible for threshold-based restart
  declare -A RESTART_DEPLOYMENTS
  RESTART_DEPLOYMENTS=(
    ["deployment=php"]="error,critical"
    ["app=redis-proxy"]="err:"
  )

  # Deployments to observe only (log errors, no restart)
  # - cron: transient DB/Redis errors during startup, auto-recovers
  # - redis-node: restart can cascade-disconnect redis-proxy
  # - web: nginx auto-recovers, restart won't help
  # - mariadb-galera: handled by dedicated Galera check at GALERA_CHECK_INTERVAL
  declare -A OBSERVE_DEPLOYMENTS
  OBSERVE_DEPLOYMENTS=(
    ["app=cron"]="error,critical"
    ["app.kubernetes.io/name=redis"]="CRITICAL,lost"
    ["deployment=web"]="emerg,crit"
  )

  # Perform health checks - restart-eligible services
  total_issues=0
  degraded_mode=0
  pods_checked=0
  issue_details=()
  service_summary=()
  for selector in "${!RESTART_DEPLOYMENTS[@]}"; do
    check_pod_health "$selector" "${RESTART_DEPLOYMENTS[$selector]}" "true"
    total_issues=$((total_issues + $?))
  done

  # Observe-only services (log errors, never restart)
  for selector in "${!OBSERVE_DEPLOYMENTS[@]}"; do
    check_pod_health "$selector" "${OBSERVE_DEPLOYMENTS[$selector]}" "false"
    total_issues=$((total_issues + $?))
  done

  check_cycle=$((check_cycle + 1))

  # Comprehensive infrastructure checks at longer interval (Galera + Redis Proxy)
  if [[ $((current_time - last_galera_check)) -ge $GALERA_CHECK_INTERVAL ]]; then

    # -- Redis Proxy readiness check --
    # The proxy can get "stuck" with stale connections after Galera/Redis changes.
    # Log-based checks only catch written errors; this validates actual pod readiness.
    proxy_pod=$(oc get pods -l app=redis-proxy --field-selector=status.phase=Running -n "$DEPLOY_NAMESPACE" -o jsonpath='{.items[0].metadata.name}' 2>&1)
    proxy_oc_exit=$?
    if [[ $proxy_oc_exit -ne 0 ]]; then
      service_summary+=("  [WARN] redis-proxy - oc query failed (exit $proxy_oc_exit)")
      issue_details+=("  [WARN] redis-proxy readiness check skipped - oc command failed")
    elif [[ -n "$proxy_pod" ]]; then
      ready=$(oc get pod "$proxy_pod" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      restarts=$(oc get pod "$proxy_pod" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
      restarts=${restarts:-0}

      if [[ "$ready" == "True" ]]; then
        service_summary+=("  [OK] redis-proxy - $proxy_pod ready (restarts: $restarts)")
      else
        service_summary+=("  [ALERT] redis-proxy - $proxy_pod NOT READY (restarts: $restarts)")
        issue_details+=("  [WARN] redis-proxy $proxy_pod is Running but NOT Ready - may have stale connections")
        issue_details+=("     Last 5 log lines:")
        while IFS= read -r line; do
          issue_details+=("       $line")
        done < <(oc logs "$proxy_pod" -n "$DEPLOY_NAMESPACE" --tail=5 2>/dev/null)
        total_issues=$((total_issues + 1))
      fi
    else
      service_summary+=("  [INFO] redis-proxy - no running pods")
    fi

    # -- Galera health check --
    echo "$(date): Performing comprehensive Galera health check..."

    # Auto-detect expected cluster size from StatefulSet spec
    galera_expected_size=""
    if oc get statefulset mariadb-galera -n "$DEPLOY_NAMESPACE" &> /dev/null; then
      galera_expected_size=$(oc get statefulset mariadb-galera -n "$DEPLOY_NAMESPACE" -o jsonpath='{.spec.replicas}')
    fi

    if [[ -n "$galera_expected_size" ]]; then
      if [[ "${MANUAL_MODE,,}" == "true" ]]; then
        echo "$(date): [MANUAL MODE] Skipping Galera auto-healing: manual intervention in progress"
        check_and_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE" "$galera_expected_size" false
        galera_status=$?
        if [[ "$galera_expected_size" == "0" ]]; then
          degraded_mode=1
          service_summary+=("  [NOTICE] mariadb-galera - intentionally parked (0 replicas, MANUAL MODE=true)")
          issue_details+=("  [INFO] Site is likely unavailable while database is intentionally parked")
          issue_details+=("  [INFO] To resume auto-healing: oc set env deployment/pod-health-monitor MANUAL_MODE=false -n $DEPLOY_NAMESPACE")
        elif [[ "$galera_expected_size" == "1" ]]; then
          degraded_mode=1
          service_summary+=("  [NOTICE] mariadb-galera - reduced availability mode (1 replica, MANUAL MODE=true)")
        fi
      else
        check_and_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE" "$galera_expected_size" true
        galera_status=$?
      fi
    else
      echo "$(date): No MariaDB Galera StatefulSet found - skipping Galera check"
      galera_status=0
    fi

    if [[ $galera_status -eq 2 ]]; then
      total_issues=$((total_issues + 5))  # Count as major issue
    elif [[ $galera_status -eq 1 ]]; then
      total_issues=$((total_issues + 1))
    fi

    last_galera_check=$current_time
  fi

  # -- Canary check: verify oc API connectivity is still alive --
  # If all selectors returned empty, it could mean the API is down, not that pods are gone.
  # A quick namespace query validates the connection is still working.
  if [[ $pods_checked -eq 0 && ${#service_summary[@]} -gt 0 ]]; then
    if ! oc get namespace "$DEPLOY_NAMESPACE" -o name &>/dev/null; then
      issue_details+=("  [ALERT] CANARY FAILED: oc API unreachable - all health checks may be stale")
      issue_details+=("     All services reported empty/failed - this is likely an API connectivity issue")
      total_issues=$((total_issues + 1))
    fi
  fi

  # Status report - detailed when issues found, periodic summary when healthy
  if [[ $total_issues -gt 0 || ${#issue_details[@]} -gt 0 ]]; then
    echo "============================================================"
    echo "$(date): Health check #$check_cycle - ${#issue_details[@]} finding(s), $total_issues action(s) taken ($pods_checked pods scanned)"
    for detail in "${service_summary[@]}"; do
      echo "$detail"
    done
    for detail in "${issue_details[@]}"; do
      echo "$detail"
    done
    echo "============================================================"
  elif [[ $((current_time - last_status_report)) -ge $STATUS_REPORT_INTERVAL ]]; then
    if [[ $degraded_mode -eq 1 ]]; then
      echo "$(date): Health check #$check_cycle - operational with degraded/parked database state ($pods_checked pods scanned, ${#error_counts[@]} tracked)"
    else
      echo "$(date): Health check #$check_cycle - all nominal ($pods_checked pods scanned, ${#error_counts[@]} tracked)"
    fi
    for detail in "${service_summary[@]}"; do
      echo "$detail"
    done
    last_status_report=$current_time
  fi

  # Wait for next check
  sleep $MONITORING_INTERVAL
done
