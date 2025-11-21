#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /scripts/_utils.sh

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

# Ensure kubeconfig is in a writeable location
export KUBECONFIG=/tmp/kubeconfig

# Set up oc to use the service account token
if [[ -n "$OPENSHIFT_TOKEN" && -n "$OPENSHIFT_SERVER" ]]; then
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true
  oc project "$DEPLOY_NAMESPACE"
fi

# Check if log aggregation is enabled
USE_LOG_AGGREGATOR=${USE_LOG_AGGREGATOR:-"true"}

# Function to run with or without log aggregation
run_with_logging() {
  if [[ "$USE_LOG_AGGREGATOR" == "true" && -f "/scripts/log-aggregator.sh" ]]; then
    echo "Starting pod health checks with log aggregation..."
    exec 1> >(bash /scripts/log-aggregator.sh pipe)
    exec 2>&1
  fi

  echo "Checking pod logs for errors..."
}

# Define the list of deployments and their corresponding error messages and handling functions
declare -A DEPLOYMENTS
DEPLOYMENTS=(
  ["deployment=php"]="error,critical"
  ["app=redis-proxy"]="err:"
  ["app.kubernetes.io/name=mariadb-galera"]="Aborted,bogus"
  # ["app.kubernetes.io/name=redis"]="lost"
  # ["deployment=web"]="error"
  # ["app=cron"]="error"
)

# Initialize logging
run_with_logging

# =============================================================================
# GALERA CLUSTER HEALTH MONITORING AND AUTO-HEALING
# =============================================================================
echo "🩺 Checking Galera cluster health..."
current_namespace=$(oc project -q)

# Check if MariaDB Galera deployment exists
if oc get statefulset mariadb-galera -n "$current_namespace" &> /dev/null; then
  galera_selector="app.kubernetes.io/name=mariadb-galera"
  expected_size=$(oc get statefulset mariadb-galera -n "$current_namespace" -o jsonpath='{.spec.replicas}')

  echo "🔍 Found Galera cluster with expected size: $expected_size pods"

  # Use the existing health check function
  health_status=0
  if check_galera_cluster_health "$galera_selector" "$current_namespace" "$expected_size"; then
    health_status=$?
  else
    health_status=$?
  fi

  case $health_status in
    0)
      echo "✅ Galera cluster is healthy - all pods synchronized"
      ;;
    1)
      echo "⚠️  Galera cluster has unhealthy pods - attempting auto-heal"
      if auto_heal_galera_cluster "$galera_selector" "$current_namespace"; then
        echo "✅ Galera auto-heal completed successfully"
      else
        echo "❌ Galera auto-heal failed - manual intervention may be required"
        # Send critical notification
        send_notification "GALERA_AUTO_HEAL_FAILED" "Galera Auto-Heal Failed" \
          "Auto-healing failed for Galera cluster in $current_namespace. Manual intervention required." \
          "error" "$current_namespace"
      fi
      ;;
    2)
      echo "🚨 CRITICAL: Galera split-brain detected - attempting emergency auto-heal"
      if auto_heal_galera_cluster "$galera_selector" "$current_namespace"; then
        echo "✅ Emergency Galera split-brain recovery completed"
        # Send healing success notification
        send_notification "GALERA_SPLIT_BRAIN_RECOVERED" "Galera Split-Brain Recovered" \
          "Successfully recovered from Galera split-brain condition in $current_namespace" \
          "healing" "$current_namespace"
      else
        echo "❌ CRITICAL: Failed to recover from Galera split-brain - IMMEDIATE ACTION REQUIRED"
        # Send critical notification
        send_notification "GALERA_SPLIT_BRAIN_CRITICAL" "CRITICAL: Galera Split-Brain Recovery Failed" \
          "Failed to recover from split-brain in $current_namespace. Database cluster may be corrupted. IMMEDIATE ACTION REQUIRED." \
          "error" "$current_namespace"
      fi
      ;;
    *)
      echo "❌ Unknown Galera health check status: $health_status"
      ;;
  esac
else
  echo "ℹ️  No MariaDB Galera StatefulSet found in namespace $current_namespace"
fi

# =============================================================================
# POD LOG CHECKING AND ERROR DETECTION
# =============================================================================
echo ""
echo "🔍 Checking pod logs for errors..."

# Main execution
total_checked=0
total_restarted=0

for selector in "${!DEPLOYMENTS[@]}"; do
  error_patterns="${DEPLOYMENTS[$selector]}"

  echo ""
  echo "════════════════════════════════════════"

  pods_before=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)

  # Special handling for mariadb-galera: check cluster health and auto-heal
  if [[ "$selector" == "app.kubernetes.io/name=mariadb-galera" ]]; then
    echo "🔍 Checking Galera cluster with selector: $selector"
    check_and_heal_galera_cluster "$selector" "$DEPLOY_NAMESPACE" 5 true
    galera_status=$?
    case $galera_status in
      0)
        echo "    ✅ Galera cluster is healthy, proceeding with log checks"
        ;;
      2)
        echo "    🔄 Galera auto-heal completed, counting as restart"
        # Auto-heal performed, count all pods as 'restarted'
        total_checked=$((total_checked + pods_before))
        total_restarted=$((total_restarted + pods_before))
        continue
        ;;
      *)
        echo "    ⚠️  Galera issues detected but continuing with log checks"
        ;;
    esac
  fi

  check_and_restart_pod "$selector" "$error_patterns"

  pods_after=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)
  restarted=$((pods_before - pods_after))

  total_checked=$((total_checked + pods_before))
  total_restarted=$((total_restarted + restarted))
done

echo ""
echo "════════════════════════════════════════"
echo "📊 SUMMARY:"
echo "   Pods checked: $total_checked"
echo "   Pods restarted: $total_restarted"
echo "   Completed at: $(date)"

if [[ $total_restarted -gt 0 ]]; then
  echo "⚠️  $total_restarted pod(s) were restarted due to errors"
  exit 1
else
  echo "✅ All pods are healthy"
  exit 0
fi
