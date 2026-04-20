#!/bin/bash
#==============================================================================
# right-sizing.sh
#==============================================================================
# PURPOSE:
#   Apply resource allocation (CPU/memory requests and limits), scaling
#   configuration (pod count, HPA settings), and Galera timeout tuning
#   to all deployments and StatefulSets based on CSV configuration.
#
# CSV FORMAT:
#   Deployment,Type,Pod Count,Max Pods,PVC Count,PVC Capacity (MiB),
#   CPU Request (m),CPU Limit (m),Mem. Request (MiB),Mem. Limit (MiB),
#   CPU Scale Value,Galera Profile
#
#   Galera Profile: default|minimal|dev|test|production|full (empty = skip)
#
# CSV SOURCE:
#   - Default: ./openshift/${DEPLOY_NAMESPACE}-sizing.csv (file)
#   - ConfigMap: Set CSV_SOURCE=configmap to read from right-sizing-config
#
# ARCHITECTURE:
#   Reads CSV file or ConfigMap: right-sizing-config
#   - Sets resource requests/limits for each deployment
#   - Scales pods to specified count (incremental for Galera)
#   - Applies Galera timeout configuration (if profile specified)
#   - Creates HorizontalPodAutoscaler if MaxPods > PodCount
#   - Skips resources with PodCount=0 (optional/temporary resources)
#
# QUICK CONFIG:
#   DEPLOY_NAMESPACE         - Determines CSV file to use (required)
#   CSV_SOURCE               - "file" (default) or "configmap"
#
# USAGE:
#   # Apply sizing for dev namespace (from file)
#   export DEPLOY_NAMESPACE="950003-dev"
#   ./openshift/scripts/right-sizing.sh
#
#   # Apply sizing from ConfigMap (in-cluster execution)
#   export DEPLOY_NAMESPACE="950003-prod"
#   export CSV_SOURCE="configmap"
#   ./openshift/scripts/right-sizing.sh
#
# IN-CLUSTER USAGE:
#   Called from pod-health-monitor after CSV uploaded to ConfigMap:
#   oc exec deployment/pod-health-monitor -n 950003-dev -- \
#     bash -c 'export DEPLOY_NAMESPACE=950003-dev; export CSV_SOURCE=configmap; bash /scripts/right-sizing.sh'
#
# CSV FILES:
#   - Dev:  ./openshift/950003-dev-sizing.csv
#   - Test: ./openshift/950003-test-sizing.csv
#   - Prod: ./openshift/950003-prod-sizing.csv
#   - ConfigMap: right-sizing-config (when CSV_SOURCE=configmap)
#
# RELATED DOCS:
#   - SharePoint source (manual export):
#     "OpenShift Cluster Right-Sizing" spreadsheet
#   - Future: Direct Microsoft Graph API integration
#   - Galera timeout tuning: docs/galera-timeout-in-cluster-architecture.md
#==============================================================================

echo "Right-sizing cluster..."

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

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

# Read deployment filter (optional - limits which deployments to process)
DEPLOYMENT_FILTER="${DEPLOYMENT_FILTER:-}"

# Function to check if a deployment should be processed
should_process_deployment() {
  local deployment=$1

  # If no filter set, process all deployments
  if [[ -z "$DEPLOYMENT_FILTER" ]]; then
    return 0
  fi

  # Check if deployment is in the filter list (comma-separated)
  IFS=',' read -ra FILTER_ARRAY <<< "$DEPLOYMENT_FILTER"
  for filter_item in "${FILTER_ARRAY[@]}"; do
    # Trim whitespace
    filter_item=$(echo "$filter_item" | xargs)
    if [[ "$deployment" == "$filter_item" ]]; then
      return 0
    fi
  done

  return 1
}

if [[ -n "$DEPLOYMENT_FILTER" ]]; then
  echo "📌 Deployment filter active: $DEPLOYMENT_FILTER"
  echo "   Only filtered deployments will be processed"
  echo ""
fi

# Determine CSV source (file or ConfigMap)
CSV_SOURCE="${CSV_SOURCE:-file}"
CSV_TEMP_FILE="/tmp/right-sizing-${DEPLOY_NAMESPACE}.csv"

if [[ "$CSV_SOURCE" == "configmap" ]]; then
  echo "Reading CSV from ConfigMap: right-sizing-config"

  # Extract CSV from ConfigMap (in-cluster execution)
  if ! oc get configmap right-sizing-config -n "$DEPLOY_NAMESPACE" -o jsonpath='{.data.sizing\.csv}' > "$CSV_TEMP_FILE" 2>/dev/null; then
    echo "[ERROR] Failed to read CSV from ConfigMap"
    echo "  Ensure ConfigMap 'right-sizing-config' exists with key 'sizing.csv'"
    exit 1
  fi

  CSV_FILE="$CSV_TEMP_FILE"
  echo "CSV loaded from ConfigMap ($(wc -l < "$CSV_FILE") lines)"
else
  # Use local file
  CSV_FILE="./openshift/${DEPLOY_NAMESPACE}-sizing.csv"

  if [[ ! -f "$CSV_FILE" ]]; then
    echo "[ERROR] CSV file not found: $CSV_FILE"
    exit 1
  fi

  echo "Using CSV file: $CSV_FILE"
fi

echo ""

# Track failures across the pipe subshell
rm -f /tmp/right-sizing-failures.txt

# Read the CSV file line by line to set deployment resources
# Header format: Deployment,Type,Pod Count,Max Pods,PVC Count,PVC Capacity (MiB),CPU Request (m),CPU Limit (m),Mem. Request (MiB),Mem. Limit (MiB),CPU Scale Value
tail -n +2 "$CSV_FILE" | while IFS=, read -r Deployment Type PodCount MaxPods PVCCount PVCCapacity CPURequest CPULimit MemRequest MemLimit CPUScaleValue
do
  # Check deployment filter first
  if ! should_process_deployment "$Deployment"; then
    echo "⏭️  Skipping $Type/$Deployment (not in filter)"
    continue
  fi

  echo "Right-sizing: $Type/$Deployment"

  # Ignore if the type is not statefulset or deployment (mainly ignores jobs)
  if [[ "$Type" == "sts" || "$Type" == "deployment" ]]; then
    set_resources "$Type" "$Deployment" "$CPURequest" "$MemRequest" "$CPULimit" "$MemLimit"
  fi

  if [[ $PodCount -eq 0 ]]; then
    echo "Skipping optional / temporary resource... no pods required to be running."
  else
    # Galera StatefulSets require special handling to prevent split-brain.
    # Use scale_galera_statefulset() which provides:
    # - Pre-flight cluster address verification
    # - Incremental scaling with sync validation
    # - Split-brain prevention and health checks
    # See: docs/galera-deployment-best-practices.md#solution-4
    if [[ "$Type" == "sts" && "$Deployment" == *"galera"* ]]; then
      echo "📈 Galera-aware scaling for $Deployment to $PodCount replicas..."
      if ! scale_galera_statefulset "$Deployment" "$PodCount" "$DEPLOY_NAMESPACE"; then
        echo "❌ $Type/$Deployment Galera scaling failed"
        echo "FAILED:$Type/$Deployment (Galera scaling)" >> /tmp/right-sizing-failures.txt
      fi
    else
      # Non-Galera deployments use standard scaling
      if ! scale_deployment "$Type" "$Deployment" "$PodCount" "$MaxPods"; then
        echo "❌ $Type/$Deployment failed to stabilize after scaling"
        # Signal failure to parent shell via temp file (pipe subshell can't set vars)
        echo "FAILED:$Type/$Deployment" >> /tmp/right-sizing-failures.txt
      fi
    fi

    # Galera-specific post-scaling operations
    # scale_galera_statefulset() already handles health checks and sync validation,
    # but we still need to handle partition resets and restarts for ConfigMap updates.
    if [[ "$Type" == "sts" && "$Deployment" == *"galera"* ]]; then

      # Ensure partition is set to 0 for Galera StatefulSets
      # Kubernetes won't restart pods if partition >= replica count
      # This can happen after scale-down or failed deployments
      echo "🔧 Ensuring partition is reset for $Deployment..."
      if ! ensure_statefulset_partition "$Deployment" "$DEPLOY_NAMESPACE" 0; then
        echo "   ❌ Failed to reset partition - restart may fail"
        echo "FAILED:$Type/$Deployment (partition reset)" >> /tmp/right-sizing-failures.txt
      fi

      # Restart StatefulSet to ensure ConfigMap changes are applied
      # Resource changes trigger automatic restarts, but ConfigMap changes
      # (like my.cnf timeout updates) require manual restart to take effect.
      # By this point, resource-based restarts have completed, so triggering
      # another restart will pick up any ConfigMap modifications.
      echo "🔄 Restarting $Deployment to apply configuration changes..."
      if restart_statefulset "$Deployment" "$DEPLOY_NAMESPACE" "600s" "true" "$PodCount"; then
        echo "✅ $Deployment restarted successfully with verified Galera health"
      else
        echo "⚠️ $Deployment restart failed or health check failed"
        echo "FAILED:$Type/$Deployment (restart or health check)" >> /tmp/right-sizing-failures.txt
      fi
    fi

    # Check if MaxPods is greater than PodCount before creating the HPA
    if [[ $MaxPods -gt $PodCount ]]; then
      create_hpa "$Deployment" "$Type/$Deployment" "$PodCount" "$MaxPods" "$CPUScaleValue"
    else
      echo "Skipping HPA creation for $Type/$Deployment: MaxPods ($MaxPods) is not greater than PodCount ($PodCount)."
    fi
  fi
done

# Apply Galera timeout configuration if profiles were specified
if [[ ${#GALERA_PROFILES[@]} -gt 0 ]]; then
  echo ""
  echo "========================================================================"
  echo "Applying Galera Timeout Configuration"
  echo "========================================================================"
  echo ""

  for deployment in "${!GALERA_PROFILES[@]}"; do
    profile="${GALERA_PROFILES[$deployment]}"
    echo "Applying profile '$profile' to $deployment..."

    # Check if apply-galera-timeouts.sh is available
    if [[ -f "/scripts/utils/apply-galera-timeouts.sh" ]]; then
      # In-cluster execution - call the utility script
      if bash /scripts/utils/apply-galera-timeouts.sh --profile "$profile" --namespace "$DEPLOY_NAMESPACE"; then
        echo "[OK] Galera timeout configuration applied to $deployment"
      else
        echo "[WARN] Failed to apply Galera timeouts to $deployment"
        echo "FAILED:$deployment (Galera timeout configuration)" >> /tmp/right-sizing-failures.txt
      fi
    elif [[ -f "config/pod-health-monitor/utils/apply-galera-timeouts.sh" ]]; then
      # Local execution - call from repo
      if bash config/pod-health-monitor/utils/apply-galera-timeouts.sh --profile "$profile" --namespace "$DEPLOY_NAMESPACE"; then
        echo "[OK] Galera timeout configuration applied to $deployment"
      else
        echo "[WARN] Failed to apply Galera timeouts to $deployment"
        echo "FAILED:$deployment (Galera timeout configuration)" >> /tmp/right-sizing-failures.txt
      fi
    else
      echo "[WARN] apply-galera-timeouts.sh not found - skipping Galera timeout configuration"
      echo "  To enable Galera tuning, ensure utility scripts are deployed to pod-health-monitor"
    fi

    echo ""
  done
fi

# Check for any failures that occurred in the pipe subshell
if [[ -f /tmp/right-sizing-failures.txt ]]; then
  echo ""
  echo "❌ RIGHT-SIZING FAILURES DETECTED:"
  cat /tmp/right-sizing-failures.txt
  echo ""
  echo "⚠️  Some resources failed to stabilize after scaling."
  echo "   The site should NOT exit maintenance mode until these are resolved."
  rm -f /tmp/right-sizing-failures.txt
  exit 1
fi

# Cleanup
rm -f /tmp/right-sizing-failures.txt
if [[ "$CSV_SOURCE" == "configmap" ]]; then
  rm -f "$CSV_TEMP_FILE"
fi

echo "✅ Right-sizing completed successfully."
