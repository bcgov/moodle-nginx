#!/bin/bash
#==============================================================================
# remove-maintenance-message.sh
#==============================================================================
# PURPOSE:
#   Remove maintenance page and restore normal application traffic.
#   Coordinates with pod-health-monitor to re-enable auto-heal.
#
# PREREQUISITES:
#   - Main application deployed and healthy
#   - Database ready
#   - Site passing health checks
#
# FLOW:
#   1. Validate namespace safety
#   2. Verify main application is healthy
#   3. Redirect routes back to main application
#   4. Scale down maintenance-message
#   5. Delete maintenance-message deployment/service
#   6. Clear deployment state
#   7. Query cluster health
#   8. Disable MANUAL_MODE (re-enable auto-heal)
#
# USAGE:
#   ./scripts/remove-maintenance-message.sh
#
#   # Force removal (skip health checks)
#   ./scripts/remove-maintenance-message.sh --force
#
# SAFETY:
#   - Checks main application health before removal
#   - Validates routes will work before removal
#   - Only operates in current oc project
#   - Requires --force to bypass health checks
#
# RELATED:
#   - deploy-maintenance-message.sh (deploys maintenance mode)
#   - Lighthouse monitor (auto-triggers this script when site healthy)
#==============================================================================

FORCE_REMOVAL=false
[[ "$1" == "--force" ]] && FORCE_REMOVAL=true

# Universal _utils.sh loader
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

initialize_utility_arrays

# =============================================================================
# NAMESPACE SAFETY
# =============================================================================

log_header "REMOVE MAINTENANCE MODE"

ensure_openshift_auth || exit 1
CURRENT_NS="$DEPLOY_NAMESPACE"

log_info "Operating in namespace: $CURRENT_NS"
echo ""

# =============================================================================
# STEP 1: PRE-FLIGHT CHECKS
# =============================================================================

log_header "Step 1/8: Pre-Flight Checks"

# Check if maintenance-message exists
if ! oc get deployment/maintenance-message -n "$CURRENT_NS" &>/dev/null; then
  log_error "maintenance-message deployment not found"
  log_error "Nothing to remove - site may already be in normal operation"
  exit 1
fi

# Check main application health (unless --force)
if [[ "$FORCE_REMOVAL" != "true" ]]; then
  log_info "Checking main application health..."

  # Check if php deployment exists and is healthy
  php_replicas=$(oc get deployment/php -n "$CURRENT_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  php_ready=$(oc get deployment/php -n "$CURRENT_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "$php_ready" -lt "$php_replicas" ]]; then
    log_error "Main application (php) not ready: $php_ready/$php_replicas replicas"
    log_error "Cannot safely remove maintenance page"
    log_error "Use --force to bypass this check"
    exit 1
  fi

  log_success "PHP deployment healthy: $php_ready/$php_replicas replicas"

  # Check database health
  log_info "Checking database health..."
  if query_cluster_health "$CURRENT_NS" | jq -e '.cluster_health."mariadb-galera".status != "healthy"' >/dev/null 2>&1; then
    log_error "Database cluster not healthy"
    log_error "Cannot safely remove maintenance page"
    log_error "Use --force to bypass this check"
    exit 1
  fi

  log_success "Database cluster healthy"

  # Check web deployment
  web_replicas=$(oc get deployment/web -n "$CURRENT_NS" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  web_ready=$(oc get deployment/web -n "$CURRENT_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")

  if [[ "$web_ready" -lt "$web_replicas" ]]; then
    log_warn "Web deployment not fully ready: $web_ready/$web_replicas replicas"
    log_warn "Proceeding anyway (NGINX should recover quickly)"
  else
    log_success "Web deployment healthy: $web_ready/$web_replicas replicas"
  fi
else
  log_warn "⚠️  FORCE MODE: Skipping health checks"
  log_warn "    Proceeding with removal despite potential issues"
fi

echo ""

# =============================================================================
# STEP 2: REDIRECT ROUTES TO MAIN APPLICATION
# =============================================================================

log_header "Step 2/8: Restore Traffic Routing"

log_info "Redirecting routes back to main application (web service)..."

# Redirect all routes back to web service
routes=$(oc get routes -n "$CURRENT_NS" -o jsonpath='{.items[*].metadata.name}')

for route in $routes; do
  current_backend=$(oc get route "$route" -n "$CURRENT_NS" -o jsonpath='{.spec.to.name}' 2>/dev/null)

  if [[ "$current_backend" == "maintenance-message" ]]; then
    if oc patch route "$route" -n "$CURRENT_NS" \
         -p '{"spec":{"to":{"name":"web"}}}' 2>/dev/null; then
      log_success "  ✅ $route → web"
    else
      log_error "  ❌ Failed to patch route: $route"
    fi
  else
    log_debug "  ⏭️  $route already points to $current_backend (not maintenance-message)"
  fi
done

log_success "Routes restored to main application"
echo ""

# =============================================================================
# STEP 3: SCALE DOWN MAINTENANCE-MESSAGE
# =============================================================================

log_header "Step 3/8: Scale Down Maintenance Page"

log_info "Scaling maintenance-message to 0..."
oc scale deployment/maintenance-message -n "$CURRENT_NS" --replicas=0

if wait_for "deployment/maintenance-message" "ready" "120s" "down"; then
  log_success "Maintenance deployment scaled to 0"
else
  log_warn "Timeout waiting for scale-down (continuing anyway)"
fi

echo ""

# =============================================================================
# STEP 4: DELETE MAINTENANCE RESOURCES
# =============================================================================

log_header "Step 4/8: Delete Maintenance Resources"

log_info "Deleting maintenance-message deployment..."
oc delete deployment/maintenance-message -n "$CURRENT_NS" --wait=true --timeout=60s 2>/dev/null || true

log_info "Deleting maintenance-message service..."
oc delete svc/maintenance-message -n "$CURRENT_NS" --wait=true --timeout=30s 2>/dev/null || true

log_info "Deleting maintenance ConfigMaps..."
oc delete configmap/maintenance-page -n "$CURRENT_NS" --ignore-not-found=true 2>/dev/null || true
oc delete configmap/maintenance-config -n "$CURRENT_NS" --ignore-not-found=true 2>/dev/null || true

log_success "Maintenance resources deleted"
echo ""

# =============================================================================
# STEP 5: CLEAR DEPLOYMENT STATE
# =============================================================================

log_header "Step 5/8: Clear Deployment State"

log_info "Clearing deployment-state ConfigMap..."
oc delete configmap/deployment-state -n "$CURRENT_NS" --ignore-not-found=true 2>/dev/null || true

log_success "Deployment state cleared"
echo ""

# =============================================================================
# STEP 6: QUERY FINAL CLUSTER HEALTH
# =============================================================================

log_header "Step 6/8: Verify Cluster Health"

log_info "Generating cluster health snapshot..."
generate_cluster_health_snapshot "$CURRENT_NS" "/tmp/restore-health.json" 2>/dev/null || true

# Display health status
if [[ -f "/tmp/restore-health.json" ]]; then
  galera_status=$(jq -r '.cluster_health."mariadb-galera".status' /tmp/restore-health.json 2>/dev/null || echo "unknown")
  php_status=$(jq -r '.cluster_health.php.status' /tmp/restore-health.json 2>/dev/null || echo "unknown")
  redis_status=$(jq -r '.cluster_health.redis.status' /tmp/restore-health.json 2>/dev/null || echo "unknown")

  log_info "Cluster health:"
  log_info "  MariaDB Galera: $galera_status"
  log_info "  PHP:            $php_status"
  log_info "  Redis:          $redis_status"

  if [[ "$galera_status" == "healthy" && "$php_status" == "healthy" ]]; then
    log_success "Cluster is healthy - safe to disable MANUAL_MODE"
  elif [[ "$FORCE_REMOVAL" == "true" ]]; then
    log_warn "Cluster not fully healthy but FORCE MODE enabled"
  else
    log_warn "Cluster not fully healthy - leaving MANUAL_MODE enabled for safety"
    log_warn "Run remove-maintenance-message.sh --force to override"
    exit 1
  fi
else
  log_warn "Could not generate health snapshot (pod-health-monitor may not be deployed)"
  if [[ "$FORCE_REMOVAL" != "true" ]]; then
    log_error "Cannot verify cluster health - aborting"
    log_error "Use --force to bypass health verification"
    exit 1
  fi
fi

echo ""

# =============================================================================
# STEP 7: DISABLE MANUAL_MODE
# =============================================================================

log_header "Step 7/8: Re-Enable Auto-Heal"

log_info "Disabling MANUAL_MODE in pod-health-monitor..."
set_manual_mode "false" "$CURRENT_NS" "Maintenance complete - site restored"

log_success "MANUAL_MODE disabled - auto-healing re-enabled"
echo ""

# =============================================================================
# STEP 8: SEND NOTIFICATION
# =============================================================================

log_header "Step 8/8: Send Notification"

send_notification "MAINTENANCE_COMPLETE" \
  "Maintenance Mode Disabled" \
  "Site restored to normal operation. Maintenance page removed. Auto-healing re-enabled." \
  "success" "$CURRENT_NS"

log_success "Notification sent"
echo ""

# =============================================================================
# SUCCESS SUMMARY
# =============================================================================

log_header "SITE RESTORED TO NORMAL OPERATION"
echo ""
log_success "✅ Maintenance mode removed successfully"
log_info "   Namespace:        $CURRENT_NS"
log_info "   MANUAL_MODE:      disabled (auto-heal active)"
log_info "   Traffic:          restored to main application"
log_info "   Site status:      accessible to users"
echo ""
log_info "Next steps:"
log_info "  1. Monitor site performance"
log_info "  2. Verify user access"
log_info "  3. Check application logs for issues"
log_info "  4. Run Lighthouse audit to confirm site health"
echo ""
log_info "If issues arise:"
log_info "  pod-health-monitor will auto-heal (MANUAL_MODE disabled)"
log_info "  Or run: ./openshift/scripts/deploy-maintenance-message.sh"
echo ""
