#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /scripts/_utils.sh

# Ensure kubeconfig is in a writeable location
export KUBECONFIG=/tmp/kubeconfig

# Set up oc to use the service account token
if [[ -n "$OPENSHIFT_TOKEN" && -n "$OPENSHIFT_SERVER" ]]; then
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true
  oc project "$DEPLOY_NAMESPACE"
fi

echo "Checking pod logs for errors..."

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

# Function to check logs for errors and restart if needed
check_and_restart_pod() {
  local selector="$1"
  local error_patterns="$2"

  echo "🔍 Checking pods with selector: $selector"

  # Get all running pods matching the selector
  local pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$pods" ]]; then
    echo "⚠️  No running pods found for selector: $selector"
    return
  fi

  # Convert comma-separated patterns to array
  IFS=',' read -ra patterns <<< "$error_patterns"

  for pod in $pods; do
    echo "  📋 Checking pod: $pod"

    # Get recent logs (last 50 lines to avoid overwhelming output)
    local logs=$(oc logs "$pod" --tail=50 2>/dev/null)

    if [[ -z "$logs" ]]; then
      echo "    ⚠️  No logs available for pod: $pod"
      continue
    fi

    local errors_found=false

    # Check for each error pattern
    for pattern in "${patterns[@]}"; do
      pattern=$(echo "$pattern" | xargs) # trim whitespace
      if [[ -n "$pattern" && "$logs" == *"$pattern"* ]]; then
        echo "    🚨 ERROR DETECTED in $pod: Found pattern '$pattern'"
        errors_found=true
        break
      fi
    done

    if [[ "$errors_found" == "true" ]]; then
      echo "    🔄 Restarting pod: $pod"
      if oc delete pod "$pod" --wait=false; then
        echo "    ✅ Pod $pod deletion initiated successfully"
      else
        echo "    ❌ Failed to delete pod: $pod"
      fi
    else
      echo "    ✅ Pod $pod is healthy (no error patterns found)"
    fi
  done
}

# Main execution
total_checked=0
total_restarted=0

for selector in "${!DEPLOYMENTS[@]}"; do
  error_patterns="${DEPLOYMENTS[$selector]}"

  echo ""
  echo "════════════════════════════════════════"

  pods_before=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)

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
