#!/bin/bash
#==============================================================================
# deploy-maintenance-message.sh
#==============================================================================
# PURPOSE:
#   Deploy standalone maintenance message page during extended outages or
#   major upgrades. Coordinates with pod-health-monitor to prevent auto-heal
#   race conditions during maintenance windows.
#
# USE CASES:
#   - Extended maintenance windows (> 30 minutes)
#   - Major version upgrades requiring extensive downtime
#   - Infrastructure changes affecting multiple services
#   - Emergency maintenance triggered by audit failures
#
# ARCHITECTURE:
#   - Deploys dedicated NGINX deployment (maintenance-message)
#   - Serves static HTML from ConfigMap (maintenance-page)
#   - Sets pod-health-monitor to MANUAL_MODE (disables auto-heal)
#   - Routes traffic via existing moodle-web route
#
# COORDINATION WITH POD-HEALTH-MONITOR:
#   1. Enables MANUAL_MODE via ConfigMap (no pod restart needed)
#   2. Sets maintenance-mode flag in cluster health state
#   3. Prevents auto-heal during planned maintenance
#   4. Timeout protection (auto-disables after configured duration)
#
# DEPLOYMENT FLOW:
#   1. Validate namespace safety (prevent cross-environment impact)
#   2. Enable MANUAL_MODE in pod-health-monitor
#   3. Create ConfigMaps (maintenance-page, maintenance-config, deployment-state)
#   4. Scale down existing deployment if present
#   5. Delete old deployment and service
#   6. Deploy maintenance.yml template
#   7. Wait for rollout completion
#   8. Redirect routes to maintenance-message
#
# CONFIGURATION:
#   BUILD_NAME               - Deployment name (default: maintenance-message)
#   DEPLOY_NAMESPACE         - Target namespace
#   WEB_IMAGE                - NGINX image to use
#   ARTIFACTORY_PULL_SECRET  - Image pull secret
#   MAINTENANCE_TIMEOUT      - MANUAL_MODE timeout in minutes (default: 120)
#   MAINTENANCE_REASON       - Reason for maintenance (default: "Planned maintenance")
#
# USAGE:
#   # Deploy maintenance page (planned maintenance)
#   export BUILD_NAME="maintenance-message"
#   export MAINTENANCE_TIMEOUT=120
#   export MAINTENANCE_REASON="Database upgrade"
#   ./openshift/scripts/deploy-maintenance-message.sh
#
#   # Remove maintenance page (restore application)
#   ./openshift/scripts/remove-maintenance-message.sh
#   # Or manually:
#   # oc delete deployment/maintenance-message
#   # oc delete svc/maintenance-message
#   # Then deploy main application
#
# RELATED DOCS:
#   - Template: ../maintenance.yml
#   - HTML: ../../config/maintenance/index.html
#   - NGINX Config: ../../config/nginx/maintenance.conf
#   - Coordination: docs/galera-deployment-best-practices.md
#==============================================================================

DEPLOYMENT_SELECTOR="deployment/$BUILD_NAME"
ROUTE_NAME="moodle-web"
MAINTENANCE_TIMEOUT="${MAINTENANCE_TIMEOUT:-120}"  # Default: 2 hours
MAINTENANCE_REASON="${MAINTENANCE_REASON:-Planned maintenance}"

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

# Check if the utility script is sourced correctly
if ! type deploy_resource_from_template &> /dev/null; then
  echo "Error: deploy_resource_from_template function not found. Ensure _utils.sh is sourced correctly."
  exit 1
fi

if ! type wait_for &> /dev/null; then
  echo "Error: wait_for function not found. Ensure _utils.sh is sourced correctly."
  exit 1
fi

# =============================================================================
# NAMESPACE SAFETY & COORDINATION
# =============================================================================

log_header "MAINTENANCE MODE DEPLOYMENT"

ensure_openshift_auth || exit 1

log_info "Operating in namespace: $DEPLOY_NAMESPACE"
log_info "Maintenance reason: $MAINTENANCE_REASON"
log_info "MANUAL_MODE timeout: $MAINTENANCE_TIMEOUT minutes"
echo ""

# =============================================================================
# STEP 1: ENABLE MANUAL_MODE (Disable auto-heal during maintenance)
# =============================================================================

log_header "Step 1/7: Enable MANUAL_MODE"

set_manual_mode "true" "$DEPLOY_NAMESPACE" "$MAINTENANCE_REASON" "$MAINTENANCE_TIMEOUT"

# Signal deployment state for pod-health-monitor auto-detection
log_info "Signaling maintenance deployment state..."
oc create configmap deployment-state \
  --from-literal=deployment_active="true" \
  --from-literal=deployment_name="maintenance-message" \
  --from-literal=deployment_type="maintenance" \
  --from-literal=deployment_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=maintenance_reason="$MAINTENANCE_REASON" \
  --dry-run=client -o yaml | oc apply -f - -n "$DEPLOY_NAMESPACE"

oc label configmap deployment-state app=pod-health-monitor --overwrite -n "$DEPLOY_NAMESPACE"

log_success "MANUAL_MODE enabled - auto-heal disabled"
echo ""

# Wait for pod-health-monitor to acknowledge (if running)
log_info "Waiting for pod-health-monitor acknowledgment..."
sleep 3
manual_mode_active=$(get_manual_mode "$DEPLOY_NAMESPACE" 2>/dev/null || echo "unknown")
if [[ "$manual_mode_active" == "true" ]]; then
  log_success "pod-health-monitor acknowledged MANUAL_MODE"
else
  log_warn "pod-health-monitor not responding (may not be deployed yet - OK)"
fi
echo ""

# =============================================================================
# STEP 2: CREATE CONFIGMAPS
# =============================================================================

log_header "Step 2/7: Create ConfigMaps"

# maintenance html page
create_or_update_configmap maintenance-page ./config/maintenance/index.html

# maintenance nginx config
create_or_update_configmap maintenance-config default.conf=./config/nginx/maintenance.conf

log_success "ConfigMaps created"
echo ""

# =============================================================================
# STEP 3-6: DEPLOY MAINTENANCE MESSAGE
# =============================================================================

log_header "Step 3/7: Check Existing Deployment"

if [[ `oc describe $DEPLOYMENT_SELECTOR 2>&1` =~ "NotFound" ]]; then
  log_info "$DEPLOYMENT_SELECTOR not found - will create new deployment"
else
  log_info "$DEPLOYMENT_SELECTOR found - scaling to 0..."
  oc scale $DEPLOYMENT_SELECTOR --replicas=0
  wait_for "$DEPLOYMENT_SELECTOR" "ready" "200s" "down"

  log_info "Deleting existing deployment..."
  oc delete $DEPLOYMENT_SELECTOR -n $DEPLOY_NAMESPACE
  oc delete svc/$BUILD_NAME -n $DEPLOY_NAMESPACE

  sleep 5
fi

echo ""
log_header "Step 4/7: Deploy Maintenance Template"

deploy_resource_from_template ./openshift/maintenance.yml \
  DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  WEB_IMAGE=$WEB_IMAGE \
  BUILD_NAME=$BUILD_NAME \
  ARTIFACTORY_PULL_SECRET=$ARTIFACTORY_PULL_SECRET

log_success "Maintenance deployment created"
echo ""

# =============================================================================
# STEP 5: WAIT FOR ROLLOUT
# =============================================================================

log_header "Step 5/7: Wait for Rollout"

# Wait for the deployment to scale to 1
if ! wait_for "$DEPLOYMENT_SELECTOR" "ready" "1500s"; then
  log_error "$DEPLOYMENT_SELECTOR failed to become ready"
  log_error "Maintenance deployment failed - leaving MANUAL_MODE enabled for safety"
  log_error "Manual intervention required"
  exit 1
fi

log_success "Maintenance deployment ready"
echo ""

# =============================================================================
# STEP 6: REDIRECT ROUTES
# =============================================================================

log_header "Step 6/7: Redirect Traffic"

log_info "Redirecting all routes to maintenance-message..."
patch_all_routes "$BUILD_NAME"

log_success "All routes redirected to maintenance page"
echo ""

# =============================================================================
# STEP 7: FINAL COORDINATION
# =============================================================================

log_header "Step 7/7: Update Cluster State"

# Generate health snapshot showing maintenance mode active
log_info "Updating cluster health snapshot..."
generate_cluster_health_snapshot "$DEPLOY_NAMESPACE" "/tmp/maintenance-health.json" 2>/dev/null || true

# Update deployment state to reflect maintenance is active
oc create configmap deployment-state \
  --from-literal=deployment_active="maintenance" \
  --from-literal=deployment_name="maintenance-message" \
  --from-literal=deployment_type="maintenance" \
  --from-literal=deployment_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --from-literal=maintenance_reason="$MAINTENANCE_REASON" \
  --from-literal=maintenance_active="true" \
  --from-literal=maintenance_site_accessible="false" \
  --dry-run=client -o yaml | oc apply -f - -n "$DEPLOY_NAMESPACE"

log_success "Cluster state updated"
echo ""

# =============================================================================
# SUCCESS SUMMARY
# =============================================================================

log_header "MAINTENANCE MODE ACTIVE"
echo ""
log_success "✅ Maintenance page deployed successfully"
log_info "   Namespace:        $DEPLOY_NAMESPACE"
log_info "   Deployment:       $BUILD_NAME"
log_info "   MANUAL_MODE:      enabled (timeout: ${MAINTENANCE_TIMEOUT}m)"
log_info "   Traffic:          redirected to maintenance page"
log_info "   Reason:           $MAINTENANCE_REASON"
echo ""
log_warn "⚠️  Auto-healing disabled - pod-health-monitor in MANUAL_MODE"
log_warn "⚠️  Site unavailable to users (maintenance page showing)"
echo ""
log_info "Next steps:"
log_info "  1. Perform maintenance tasks"
log_info "  2. Deploy updated application"
log_info "  3. Run: ./openshift/scripts/remove-maintenance-message.sh"
log_info "     (or let Lighthouse monitor auto-disable when site is healthy)"
echo ""
log_info "Manual MANUAL_MODE disable:"
log_info "  ./openshift/scripts/utils/set-manual-mode.sh false"
echo ""
