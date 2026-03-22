#!/bin/bash
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

# Track consecutive errors per pod
declare -A error_counts

# Initialize logging
echo "Starting continuous pod health monitoring..."
echo "Monitoring interval: ${MONITORING_INTERVAL}s"
echo "Galera check interval: ${GALERA_CHECK_INTERVAL}s"
echo "Error threshold: ${ERROR_THRESHOLD}"

# Source utilities (same pattern as other scripts)
source /scripts/_utils.sh

# Authenticate with OpenShift API (same as check-pod-logs.sh)
if [[ -n "$OPENSHIFT_TOKEN" && -n "$OPENSHIFT_SERVER" ]]; then
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true
  oc project "$DEPLOY_NAMESPACE" 2>/dev/null || true
else
  echo "WARNING: OPENSHIFT_TOKEN or OPENSHIFT_SERVER not set — oc commands will use pod SA token"
fi

# Function for lightweight pod health check
quick_health_check() {
  local selector="$1"
  local error_patterns="$2"
  local check_name="$3"

  local pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$pods" ]]; then
    return 0
  fi

  local issues_found=0

  for pod in $pods; do
    # Quick log check (last 10 lines only for efficiency)
    local recent_logs=$(oc logs "$pod" --tail=10 2>/dev/null)

    if [[ -z "$recent_logs" ]]; then
      continue
    fi

    # Convert patterns to array and check
    IFS=',' read -ra patterns <<< "$error_patterns"
    local pod_has_errors=false

    for pattern in "${patterns[@]}"; do
      pattern=$(echo "$pattern" | xargs)
      if [[ -n "$pattern" && "$recent_logs" == *"$pattern"* ]]; then
        # Increment error count for this pod
        error_counts["$pod"]=$((${error_counts["$pod"]:-0} + 1))
        pod_has_errors=true
        echo "$(date): Error detected in $pod (count: ${error_counts["$pod"]}): $pattern"
        break
      fi
    done

    # Reset error count if no errors found
    if [[ "$pod_has_errors" == "false" ]]; then
      error_counts["$pod"]=0
    fi

    # Restart pod if error threshold reached
    if [[ ${error_counts["$pod"]:-0} -ge $ERROR_THRESHOLD ]]; then
      echo "$(date): Restarting $pod after $ERROR_THRESHOLD consecutive errors"
      if oc delete pod "$pod" --wait=false; then
        send_notification "POD_RESTART_THRESHOLD" "Pod Restarted - Error Threshold" "Pod $pod restarted after $ERROR_THRESHOLD consecutive errors. Selector: $selector" "warning" "$DEPLOY_NAMESPACE"
        error_counts["$pod"]=0
        issues_found=$((issues_found + 1))
      fi
    fi
  done

  return $issues_found
}

# Main monitoring loop
last_galera_check=0

# Send startup notification
send_notification "MONITORING_START" "Pod Health Monitor Started" "Continuous monitoring active with ${MONITORING_INTERVAL}s intervals. Galera checks every ${GALERA_CHECK_INTERVAL}s." "white_check_mark" "$DEPLOY_NAMESPACE"

while true; do
  current_time=$(date +%s)

  # Define deployments to monitor (same as CronJob)
  declare -A DEPLOYMENTS
  DEPLOYMENTS=(
    ["deployment=php"]="error,critical"
    ["app=redis-proxy"]="err:"
    ["app.kubernetes.io/name=mariadb-galera"]="Aborted,bogus"
  )

  # Perform quick health checks
  total_issues=0
  for selector in "${!DEPLOYMENTS[@]}"; do
    error_patterns="${DEPLOYMENTS[$selector]}"

    # Skip Galera for quick checks (it has its own interval)
    if [[ "$selector" == "app.kubernetes.io/name=mariadb-galera" ]]; then
      continue
    fi

    quick_health_check "$selector" "$error_patterns" "QuickCheck"
    total_issues=$((total_issues + $?))
  done

  # Comprehensive Galera check at longer interval
  if [[ $((current_time - last_galera_check)) -ge $GALERA_CHECK_INTERVAL ]]; then
    echo "$(date): Performing comprehensive Galera health check..."

    # Auto-detect expected cluster size from StatefulSet spec
    galera_expected_size=""
    if oc get statefulset mariadb-galera -n "$DEPLOY_NAMESPACE" &> /dev/null; then
      galera_expected_size=$(oc get statefulset mariadb-galera -n "$DEPLOY_NAMESPACE" -o jsonpath='{.spec.replicas}')
    fi

    if [[ -n "$galera_expected_size" ]]; then
      check_and_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE" "$galera_expected_size" true
      galera_status=$?
    else
      echo "$(date): No MariaDB Galera StatefulSet found — skipping Galera check"
      galera_status=0
    fi

    if [[ $galera_status -eq 2 ]]; then
      total_issues=$((total_issues + 5))  # Count as major issue
    elif [[ $galera_status -eq 1 ]]; then
      total_issues=$((total_issues + 1))
    fi

    last_galera_check=$current_time
  fi

  # Brief status report (don't spam logs)
  if [[ $total_issues -gt 0 ]]; then
    echo "$(date): Health check completed - $total_issues issue(s) found and addressed"
  elif [[ $((current_time % 3600)) -eq 0 ]]; then  # Hourly "alive" message
    echo "$(date): Health monitoring active - all systems nominal"
  fi

  # Wait for next check
  sleep $MONITORING_INTERVAL
done
