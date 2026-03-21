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

# Source utility functions
source ./openshift/scripts/_utils.sh

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

# ConfigMaps are managed by deploy-template.sh

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
  # Ensure ConfigMaps are up to date
  # ConfigMaps are already created by deploy-template.sh
  echo "📋 Using existing monitoring ConfigMaps..."

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
