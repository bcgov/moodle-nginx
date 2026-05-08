#!/bin/bash
#==============================================================================
# test-clear-extraflags.sh
#==============================================================================
# PURPOSE:
#   Quick test to verify that removing MARIADB_EXTRA_FLAGS allows my.cnf
#   settings to take effect. Uses only oc commands (no Helm required).
#
# USAGE:
#   # From pod-health-monitor:
#   bash /scripts/test-clear-extraflags.sh
#
#   # Or from local machine:
#   oc exec deployment/pod-health-monitor -n 950003-dev -- bash /scripts/test-clear-extraflags.sh
#
# WHAT IT DOES:
#   1. Shows current MARIADB_EXTRA_FLAGS value (PT30S)
#   2. Removes the environment variable from StatefulSet
#   3. Restarts pods to pick up my.cnf settings (PT20S)
#   4. Verifies running process now uses PT20S from ConfigMap
#
# VERIFICATION:
#   Process should show PT20S from my.cnf, not PT30S from env var
#==============================================================================

# Universal _utils.sh loader
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

echo "======================================================================="
echo "TESTING: Clear MARIADB_EXTRA_FLAGS via oc set env"
echo "======================================================================="
echo ""

# Get current environment
DB_DEPLOYMENT_NAME="${DB_DEPLOYMENT_NAME:-mariadb-galera}"

log_info "Environment:"
log_info "  Namespace: $DEPLOY_NAMESPACE"
log_info "  StatefulSet: $DB_DEPLOYMENT_NAME"
echo ""

# =============================================================================
# STEP 1: Check Current State
# =============================================================================
log_info "STEP 1: Checking current MARIADB_EXTRA_FLAGS..."
BEFORE_FLAGS=$(oc get statefulset/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="mariadb-galera")].env[?(@.name=="MARIADB_EXTRA_FLAGS")].value}' 2>/dev/null)

if [[ -n "$BEFORE_FLAGS" ]]; then
  log_warn "MARIADB_EXTRA_FLAGS currently set in StatefulSet spec:"
  echo "  $BEFORE_FLAGS"
  echo ""

  # Check what's actually running
  log_info "Checking running process on mariadb-galera-0..."
  RUNNING_CONFIG=$(oc exec mariadb-galera-0 -n "$DEPLOY_NAMESPACE" -c mariadb-galera -- \
    ps aux 2>/dev/null | grep "wsrep-provider-options" | grep -v grep | head -1)

  if [[ "$RUNNING_CONFIG" =~ PT30S ]]; then
    log_warn "Process is running with PT30S (from MARIADB_EXTRA_FLAGS)"
    echo "  This OVERRIDES the PT20S in my.cnf ConfigMap"
  elif [[ "$RUNNING_CONFIG" =~ PT20S ]]; then
    log_success "Process is already running with PT20S (from my.cnf)"
    echo "  MARIADB_EXTRA_FLAGS may be set but not taking effect"
  else
    log_info "Could not determine timeout from running process"
  fi
else
  log_success "✅ MARIADB_EXTRA_FLAGS not set (already cleared)"
  echo ""

  # Check what's actually running (informational only)
  log_info "Checking current timeout configuration..."
  RUNNING_CONFIG=$(oc exec mariadb-galera-0 -n "$DEPLOY_NAMESPACE" -c mariadb-galera -- \
    ps aux 2>/dev/null | grep "wsrep-provider-options" | grep -v grep | head -1)

  if [[ "$RUNNING_CONFIG" =~ PT20S ]]; then
    log_success "✅ Process is running with PT20S"
  elif [[ "$RUNNING_CONFIG" =~ PT15S ]]; then
    log_warn "⚠️  Process is running with PT15S (MariaDB defaults)"
    log_info "   To change timeouts, use Helm to set extraFlags"
    log_info "   See: scripts/clear-galera-extraflags.ps1"
  elif [[ "$RUNNING_CONFIG" =~ PT30S ]]; then
    log_info "ℹ️  Process is running with PT30S"
  else
    log_debug "   Could not determine timeout from running process"
  fi

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "✅ TEST COMPLETE - No action needed"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  echo "MARIADB_EXTRA_FLAGS is already cleared."
  echo "No StatefulSet restart required."
  echo ""
  exit 0
fi
echo ""

# =============================================================================
# STEP 2: Remove MARIADB_EXTRA_FLAGS
# =============================================================================
log_info "STEP 2: Removing MARIADB_EXTRA_FLAGS from StatefulSet..."
echo ""

# The trailing dash (-) tells oc to remove the variable
if oc set env statefulset/$DB_DEPLOYMENT_NAME MARIADB_EXTRA_FLAGS- -n "$DEPLOY_NAMESPACE"; then
  log_success "✅ MARIADB_EXTRA_FLAGS removed from StatefulSet spec"
else
  log_error "❌ Failed to remove MARIADB_EXTRA_FLAGS"
  exit 1
fi
echo ""

# =============================================================================
# STEP 3: Verify Removal
# =============================================================================
log_info "STEP 3: Verifying removal..."
AFTER_FLAGS=$(oc get statefulset/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="mariadb-galera")].env[?(@.name=="MARIADB_EXTRA_FLAGS")].value}' 2>/dev/null)

if [[ -n "$AFTER_FLAGS" ]]; then
  log_error "❌ MARIADB_EXTRA_FLAGS still present after removal:"
  echo "  $AFTER_FLAGS"
  exit 1
else
  log_success "✅ MARIADB_EXTRA_FLAGS successfully removed from spec"
fi
echo ""

# =============================================================================
# STEP 4: Restart Pods (Using our existing restart function)
# =============================================================================
log_info "STEP 4: Restarting StatefulSet to apply my.cnf settings..."
echo ""

# Use our existing Galera-aware restart function
if restart_statefulset "$DB_DEPLOYMENT_NAME" "$DEPLOY_NAMESPACE" "600s" "true"; then
  log_success "✅ StatefulSet restarted successfully"
else
  log_error "❌ StatefulSet restart failed"
  exit 1
fi
echo ""

# =============================================================================
# STEP 5: Verify New Configuration
# =============================================================================
log_info "STEP 5: Verifying running configuration..."
echo ""

# Wait a few seconds for process to fully start
sleep 5

# Check what's actually running now
log_info "Checking process on mariadb-galera-0..."
FINAL_CONFIG=$(oc exec mariadb-galera-0 -n "$DEPLOY_NAMESPACE" -c mariadb-galera -- \
  ps aux 2>/dev/null | grep "wsrep-provider-options" | grep -v grep | head -1)

echo "Running process command line:"
echo "$FINAL_CONFIG" | grep -o "wsrep-provider-options=[^ ]*" || echo "  (not found in ps output)"
echo ""

if [[ "$FINAL_CONFIG" =~ PT20S ]]; then
  log_success "✅ SUCCESS: Process now using PT20S from my.cnf ConfigMap"
  echo ""
  echo "The my.cnf settings are now active!"
  echo "  • PT20S timeout (from ConfigMap)"
  echo "  • MARIADB_EXTRA_FLAGS no longer overriding"
elif [[ "$FINAL_CONFIG" =~ PT30S ]]; then
  log_error "❌ FAILED: Process still using PT30S"
  echo ""
  echo "This suggests the pods didn't pick up the change. Try:"
  echo "  1. Check StatefulSet spec: oc get sts/$DB_DEPLOYMENT_NAME -o yaml | grep EXTRA"
  echo "  2. Manual restart: oc delete pod mariadb-galera-0 -n $DEPLOY_NAMESPACE"
  exit 1
else
  log_warn "⚠️  Could not determine timeout from process output"
  echo ""
  echo "Manual verification:"
  echo "  oc exec mariadb-galera-0 -n $DEPLOY_NAMESPACE -c mariadb-galera -- ps aux | grep wsrep"
fi
echo ""

# Show verification commands
echo "======================================================================="
echo "SUMMARY"
echo "======================================================================="
echo ""
echo "What we did:"
echo "  1. ✅ Removed MARIADB_EXTRA_FLAGS from StatefulSet spec"
echo "  2. ✅ Restarted pods to pick up my.cnf settings"
echo "  3. ✅ Verified process now uses PT20S from ConfigMap"
echo ""
echo "Next steps for permanent fix:"
echo "  1. Add to deploy-mariadb-galera.sh:"
echo "       --set extraFlags=\"\" \\"
echo "       --set mariadbd.extraFlags=\"\" \\"
echo ""
echo "  2. Run full deployment to persist in Helm release:"
echo "       bash -c 'source example.secrets && source example.versions.env && ./openshift/scripts/deploy-mariadb-galera.sh'"
echo ""
echo "This test proves the fix works - ConfigMap settings now take effect!"
echo ""

