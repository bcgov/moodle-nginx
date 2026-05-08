#!/bin/bash
# =============================================================================
# HEALTH MONITOR DEPLOYMENT SCRIPT
# =============================================================================
# Purpose: Deploys pod health monitoring infrastructure with webhook notifications
#          Manages ConfigMaps, secrets, and monitoring deployment/CronJob
#
# Deployment Options:
#   DEPLOYMENT_TYPE=continuous  - Long-running deployment (recommended)
#   DEPLOYMENT_TYPE=cronjob     - Scheduled CronJob execution (fallback)
#
# Prerequisites:
#   - ConfigMaps created by deploy-template.sh:
#     • check-pod-logs-script (core monitoring logic + utilities)
#     • pod-health-monitor-script (continuous monitoring wrapper)
#     • log-aggregator-script (event forwarding)
#   - Service account with pod read/delete/logs permissions
#   - Optional: ROCKETCHAT_WEBHOOK_URL for notifications
#
# What This Script Does:
#   1. Validates environment variables (namespace, server, service account)
#   2. Creates/updates notification-webhooks secret (synced from GitHub)
#   3. Deploys continuous monitoring OR CronJob based on DEPLOYMENT_TYPE
#   4. Tests webhook connectivity
#   5. Waits for deployment readiness
#
# Configuration:
#   DEPLOY_NAMESPACE          - Target OpenShift namespace (required)
#   OPENSHIFT_SERVER          - OpenShift API server URL (required)
#   OPENSHIFT_SA_TOKEN_NAME   - Service account secret name (required)
#   ROCKETCHAT_WEBHOOK_URL    - RocketChat webhook for notifications (optional)
#   DEPLOYMENT_TYPE           - "continuous" or "cronjob" (default: continuous)
#
# Related Documentation:
#   - Architecture: ../../docs/galera-monitoring-solution.md
#   - Templates: ../pod-health-monitor.yml, ../check-pod-logs.yml
#   - Monitoring script: ./check-pod-logs.sh
# =============================================================================

set -euo pipefail

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

# Configuration
DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE:-}"
OPENSHIFT_SERVER="${OPENSHIFT_SERVER:-}"
OPENSHIFT_SA_TOKEN_NAME="${OPENSHIFT_SA_TOKEN_NAME:-}"
ROCKETCHAT_WEBHOOK_URL="${ROCKETCHAT_WEBHOOK_URL:-}"
DEPLOYMENT_TYPE="${DEPLOYMENT_TYPE:-continuous}"  # "continuous" or "cronjob"
MONITOR_IMAGE="${MONITOR_IMAGE:-}"

# Validation
required_vars=(
  "DEPLOY_NAMESPACE"
  "OPENSHIFT_SERVER"
  "OPENSHIFT_SA_TOKEN_NAME"
  "MONITOR_IMAGE"
)

missing_vars=()
for var_name in "${required_vars[@]}"; do
  if [[ -z "${!var_name:-}" ]]; then
    missing_vars+=("$var_name")
  fi
done

if [[ ${#missing_vars[@]} -gt 0 ]]; then
  echo "Error: Required environment variables not set"
  echo "Missing: ${missing_vars[*]}"
  echo "Required: DEPLOY_NAMESPACE, OPENSHIFT_SERVER, OPENSHIFT_SA_TOKEN_NAME, MONITOR_IMAGE"
  exit 1
fi

echo "🔧 Configuring pod health monitoring deployment..."
echo "Namespace: $DEPLOY_NAMESPACE"
echo "Deployment type: $DEPLOYMENT_TYPE"
echo "Monitor image: $MONITOR_IMAGE"
echo "Webhook configured: $([ -n "$ROCKETCHAT_WEBHOOK_URL" ] && echo "Yes" || echo "No")"

# Function to deploy webhook secret
deploy_webhook_secret() {
  echo "📡 Configuring webhook notifications..."

  # Create or update the webhook secret - always refresh to sync from GitHub
  if oc get secret notification-webhooks -n "$DEPLOY_NAMESPACE" >/dev/null 2>&1; then
    echo "Updating existing webhook secret..."
    oc delete secret notification-webhooks -n "$DEPLOY_NAMESPACE"
  fi

  # Create the secret with current webhook URL (synced from GitHub)
  oc create secret generic notification-webhooks \
    -n "$DEPLOY_NAMESPACE" \
    --from-literal=rocketchat-webhook-url="$ROCKETCHAT_WEBHOOK_URL"

  # Label the secret for tracking
  oc label secret notification-webhooks -n "$DEPLOY_NAMESPACE" \
    app.kubernetes.io/component=monitoring \
    app.kubernetes.io/managed-by=github-workflow \
    --overwrite

  echo "✅ Webhook secret configured and synced from GitHub"
}

# ConfigMaps are managed by deploy-template.sh (legacy individual ConfigMaps)
# The openshift-scripts ConfigMap is the one actually mounted by pod-health-monitor

# Function to create/update the openshift-scripts ConfigMap from CI workspace
# This is the ConfigMap mounted at /scripts/ in the pod-health-monitor container.
# Uses create_or_update_configmap() from openshift.sh for consistency.
create_monitoring_configmaps() {
  local scripts_dir="./openshift/scripts"

  if [[ ! -d "$scripts_dir" ]]; then
    echo "⚠️  Scripts directory not found: $scripts_dir (not in CI workspace?)"
    echo "   openshift-scripts ConfigMap will not be updated."
    return 0
  fi

  echo "📦 Creating openshift-scripts ConfigMap from CI workspace..."

  # CI/CD-only scripts excluded to stay under 1MB ConfigMap limit.
  # These run only in GitHub Actions workflows, not in the monitor pod.
  local -a exclude_patterns=(
    "deploy-*" "build-*" "migrate-*" "optimize-*"
    "validate-*" "test-*" "comprehensive-*" "ensure-*"
    "right-sizing*" "helm-image-*" "populate-*"
    "lighthouse-*" "fix-mojibake-*" "moodle-mojibake-*"
    "openshift-list-*" "moodle-upgrade*" "enable-maintenance*"
    "deploy-memcached*"
  )

  # Collect scripts, flatten paths (utils/database.sh → utils-database.sh)
  local -a file_args=()
  local count=0
  while IFS= read -r -d '' script_file; do
    local rel_path="${script_file#${scripts_dir}/}"
    # Skip legacy files
    [[ "$rel_path" == *"-legacy.sh" ]] && continue
    # Apply exclusion patterns
    local base_name
    base_name=$(basename "$rel_path")
    local excluded=false
    for pattern in "${exclude_patterns[@]}"; do
      # shellcheck disable=SC2254
      case "$base_name" in $pattern) excluded=true; break ;; esac
    done
    [[ "$excluded" == "true" ]] && continue

    # Flatten key: utils/database.sh → utils-database.sh
    local key_name="${rel_path//\//-}"
    file_args+=("${key_name}=${script_file}")
    count=$((count + 1))
  done < <(find "$scripts_dir" -name "*.sh" -type f -print0 2>/dev/null | sort -z)

  if [[ $count -eq 0 ]]; then
    echo "⚠️  No scripts found — skipping ConfigMap creation"
    return 0
  fi

  # Use shared utility to delete-and-create atomically
  create_or_update_configmap "openshift-scripts" "${file_args[@]}"

  # Log size for ConfigMap limit monitoring (1MB max)
  local cm_size
  cm_size=$(oc get configmap openshift-scripts -n "$DEPLOY_NAMESPACE" -o json 2>/dev/null | wc -c)
  local cm_kb=$(( cm_size / 1024 ))
  echo "✅ openshift-scripts ConfigMap: $count scripts, ~${cm_kb} KB"

  # Also create openshift-resources ConfigMap (sizing CSVs, deployment YAMLs)
  echo "📦 Creating openshift-resources ConfigMap..."
  local -a resource_args=()
  local res_count=0

  # Sizing CSVs and deployment YAMLs
  while IFS= read -r -d '' res_file; do
    local res_name
    res_name=$(basename "$res_file")
    resource_args+=("${res_name}=${res_file}")
    res_count=$((res_count + 1))
  done < <(find ./openshift -maxdepth 1 \( -name "*.csv" -o -name "*.yml" \) -type f -print0 2>/dev/null | sort -z)

  # Dependencies
  if [[ -d "./openshift/dependencies" ]]; then
    while IFS= read -r -d '' dep_file; do
      local dep_name
      dep_name=$(basename "$dep_file")
      resource_args+=("dependencies-${dep_name}=${dep_file}")
      res_count=$((res_count + 1))
    done < <(find ./openshift/dependencies -type f -print0 2>/dev/null | sort -z)
  fi

  if [[ $res_count -gt 0 ]]; then
    create_or_update_configmap "openshift-resources" "${resource_args[@]}"
    echo "✅ openshift-resources ConfigMap: $res_count files"
  fi
}

# Function to deploy continuous monitoring
deploy_continuous_monitoring() {
  echo "🚀 Deploying continuous pod health monitoring..."

  # Remove existing CronJob if it exists
  if oc get cronjob check-pod-logs -n "$DEPLOY_NAMESPACE" >/dev/null 2>&1; then
    echo "Removing existing CronJob..."
    oc delete cronjob check-pod-logs -n "$DEPLOY_NAMESPACE"
  fi

  # Deploy the continuous monitoring deployment
  deploy_resource_from_template "openshift/pod-health-monitor.yml" \
    "DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE" \
    "OPENSHIFT_SERVER=$OPENSHIFT_SERVER" \
    "OPENSHIFT_SA_TOKEN_NAME=$OPENSHIFT_SA_TOKEN_NAME" \
    "ROCKETCHAT_WEBHOOK_URL=$ROCKETCHAT_WEBHOOK_URL" \
    "MONITORING_INTERVAL=60" \
    "MONITOR_IMAGE=$MONITOR_IMAGE"

  # Label the deployment for tracking
  oc label deployment pod-health-monitor -n "$DEPLOY_NAMESPACE" \
    app.kubernetes.io/managed-by=github-workflow \
    app.kubernetes.io/version="$(date +%Y%m%d%H%M%S)" \
    --overwrite >/dev/null 2>&1

  echo "✅ Continuous monitoring deployed"
}

# Function to deploy CronJob (fallback)
deploy_cronjob_monitoring() {
  echo "⏰ Deploying CronJob-based monitoring..."

  # Remove existing deployment if it exists
  if oc get deployment pod-health-monitor -n "$DEPLOY_NAMESPACE" >/dev/null 2>&1; then
    echo "Removing existing deployment..."
    oc delete deployment pod-health-monitor -n "$DEPLOY_NAMESPACE"
  fi

  # Deploy the CronJob
  deploy_resource_from_template "openshift/check-pod-logs.yml" \
    "DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE" \
    "OPENSHIFT_SERVER=$OPENSHIFT_SERVER" \
    "OPENSHIFT_SA_TOKEN_NAME=$OPENSHIFT_SA_TOKEN_NAME" \
    "ROCKETCHAT_WEBHOOK_URL=$ROCKETCHAT_WEBHOOK_URL" \
    "MONITOR_IMAGE=$MONITOR_IMAGE"

  echo "✅ CronJob monitoring deployed"
}

# Function to test webhook connectivity
test_webhook() {
  if [[ -n "$ROCKETCHAT_WEBHOOK_URL" ]]; then
    echo "🔍 Testing webhook connectivity..."

    local test_payload='{"text": "🧪 Pod Health Monitor deployment test - webhook connectivity verified"}'

    if curl -s -X POST "$ROCKETCHAT_WEBHOOK_URL" \
       -H 'Content-Type: application/json' \
       -d "$test_payload" >/dev/null 2>&1; then
      echo "✅ Webhook test successful"
    else
      echo "⚠️  Webhook test failed - notifications may not work"
    fi
  else
    echo "ℹ️  No webhook configured - skipping test"
  fi
}

# Main execution
main() {
  # Create/update the openshift-scripts ConfigMap (mounted by pod-health-monitor)
  # This ensures every deployment gets the latest monitoring scripts.
  create_monitoring_configmaps

  # Configure webhook secret if provided
  if [[ -n "$ROCKETCHAT_WEBHOOK_URL" ]]; then
    deploy_webhook_secret
  fi

  # Deploy based on type
  case "$DEPLOYMENT_TYPE" in
    "continuous")
      deploy_continuous_monitoring
      if wait_for_deployment_without_errors "deployment/pod-health-monitor"; then
        test_webhook
      fi
      ;;
    "cronjob")
      deploy_cronjob_monitoring
      echo "✅ CronJob deployed - will run every 5 minutes"
      ;;
    *)
      echo "❌ Invalid deployment type: $DEPLOYMENT_TYPE"
      echo "Valid options: continuous, cronjob"
      exit 1
      ;;
  esac

  echo ""
  echo "🎉 Deployment completed successfully!"
  echo ""
  echo "📊 Monitoring capabilities:"
  echo "  • Pod log error detection and restart"
  echo "  • Galera cluster health monitoring"
  echo "  • Split-brain detection and auto-healing"
  echo "  • Webhook notifications for critical events"
  echo ""
  echo "🔍 To monitor the health checker:"
  if [[ "$DEPLOYMENT_TYPE" == "continuous" ]]; then
    echo "  oc logs -f deployment/pod-health-monitor -n $DEPLOY_NAMESPACE"
  else
    echo "  oc logs -f job/\$(oc get jobs -n $DEPLOY_NAMESPACE -l job-name=check-pod-logs --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}') -n $DEPLOY_NAMESPACE"
  fi
  echo ""
  echo "📡 To check webhook notifications:"
  echo "  oc get events -n $DEPLOY_NAMESPACE --field-selector component=galera-monitor"
}

# Run main function
main "$@"
