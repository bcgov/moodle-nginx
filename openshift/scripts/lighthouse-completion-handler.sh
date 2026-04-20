#!/bin/bash
#==============================================================================
# lighthouse-completion-handler.sh
#==============================================================================
# PURPOSE:
#   Lighthouse audit completion handler - coordinates with pod-health-monitor
#   to auto-disable maintenance mode when site is confirmed healthy.
#
# INTEGRATION:
#   Called by GitHub Actions lighthouse-monitor.yml after audit completes.
#   Acts as deployment completion signal for pod-health-monitor coordination.
#
# FLOW:
#   1. Validates namespace safety
#   2. Checks if MANUAL_MODE is enabled
#   3. Analyzes Lighthouse audit results
#   4. If site healthy: triggers remove-maintenance-message.sh
#   5. If site unhealthy: leaves maintenance mode enabled, sends alert
#
# LIGHTHOUSE EXIT CODES:
#   0 = All audits passed (site healthy)
#   1 = Some audits failed (site degraded but functional)
#   2 = Critical failure (site broken)
#
# USAGE (from GitHub Actions):
#   - name: Lighthouse Completion Handler
#     if: always()  # Run even if lighthouse failed
#     run: bash ./openshift/scripts/lighthouse-completion-handler.sh
#     env:
#       LIGHTHOUSE_EXIT_CODE: ${{ steps.lighthouse.outcome }}
#       LIGHTHOUSE_WARNINGS: ${{ steps.lighthouse.outputs.warnings }}
#       DEPLOY_NAMESPACE: ${{ inputs.DEPLOY_NAMESPACE }}
#
# MANUAL USAGE:
#   LIGHTHOUSE_EXIT_CODE=0 ./openshift/scripts/lighthouse-completion-handler.sh
#
# ENVIRONMENT VARIABLES:
#   LIGHTHOUSE_EXIT_CODE   - Exit code from lighthouse audit
#   LIGHTHOUSE_WARNINGS    - Number of warnings (optional)
#   DEPLOY_NAMESPACE       - Target namespace (optional, auto-detected)
#   AUTO_DISABLE_MAINTENANCE - "YES" to auto-disable (default: YES)
#
# RELATED:
#   - .github/workflows/lighthouse-monitor.yml
#   - deploy-maintenance-message.sh
#   - remove-maintenance-message.sh
#==============================================================================

# Configuration
AUTO_DISABLE_MAINTENANCE="${AUTO_DISABLE_MAINTENANCE:-YES}"
LIGHTHOUSE_EXIT_CODE="${LIGHTHOUSE_EXIT_CODE:-1}"
LIGHTHOUSE_WARNINGS="${LIGHTHOUSE_WARNINGS:-0}"

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

log_header "LIGHTHOUSE COMPLETION HANDLER"

if ! ensure_openshift_auth; then
  log_warn "OpenShift auth not available - skipping maintenance mode coordination"
  exit 0
fi
CURRENT_NS="$DEPLOY_NAMESPACE"

log_info "Namespace: $DEPLOY_NAMESPACE"
log_info "Lighthouse exit code: $LIGHTHOUSE_EXIT_CODE"
log_info "Lighthouse warnings: $LIGHTHOUSE_WARNINGS"
echo ""

# =============================================================================
# CHECK IF MANUAL_MODE IS ENABLED
# =============================================================================

log_header "Check Deployment State"

local manual_mode maintenance_active deployment_active
manual_mode=$(get_manual_mode "$DEPLOY_NAMESPACE" 2>/dev/null || echo "false")
maintenance_active=$(oc get configmap deployment-state -n "$DEPLOY_NAMESPACE" \
  -o jsonpath='{.data.maintenance_active}' 2>/dev/null || echo "false")
deployment_active=$(oc get configmap deployment-state -n "$DEPLOY_NAMESPACE" \
  -o jsonpath='{.data.deployment_active}' 2>/dev/null || echo "false")

log_info "MANUAL_MODE: $manual_mode"
log_info "Maintenance active: $maintenance_active"
log_info "Deployment active: $deployment_active"

if [[ "$manual_mode" != "true" && "$maintenance_active" != "true" ]]; then
  log_info "Site not in maintenance mode - nothing to do"
  exit 0
fi

echo ""

# =============================================================================
# ANALYZE LIGHTHOUSE RESULTS
# =============================================================================

log_header "Analyze Lighthouse Results"

local site_status
case "$LIGHTHOUSE_EXIT_CODE" in
  0)
    site_status="healthy"
    log_success "✅ Lighthouse: ALL AUDITS PASSED"
    log_success "   Site is healthy and accessible to users"
    ;;
  1)
    site_status="degraded"
    log_warn "⚠️ Lighthouse: SOME WARNINGS ($LIGHTHOUSE_WARNINGS warnings)"
    log_warn "   Site is functional but may have issues"
    ;;
  2|*)
    site_status="unhealthy"
    log_error "❌ Lighthouse: CRITICAL FAILURE"
    log_error "   Site is broken or inaccessible"
    ;;
esac

echo ""

# =============================================================================
# DECISION LOGIC
# =============================================================================

log_header "Maintenance Mode Decision"

if [[ "$site_status" == "healthy" ]]; then
  # Site is confirmed healthy
  log_success "Site confirmed healthy by Lighthouse"

  if [[ "$AUTO_DISABLE_MAINTENANCE" == "YES" ]]; then
    log_info "AUTO_DISABLE_MAINTENANCE=YES - removing maintenance mode"
    echo ""

    # Call remove-maintenance-message.sh
    if bash "$(dirname "${BASH_SOURCE[0]}")/remove-maintenance-message.sh"; then
      log_success "✅ Maintenance mode automatically disabled"
      log_success "   Site restored to normal operation"

      send_notification "LIGHTHOUSE_AUTO_RESTORE" \
        "Site Restored - Lighthouse Confirmed Healthy" \
        "Lighthouse audit passed all checks. Maintenance mode auto-disabled. Site accessible." \
        "success" "$DEPLOY_NAMESPACE"
    else
      log_error "Failed to automatically remove maintenance mode"
      log_error "Manual intervention required"

      send_notification "LIGHTHOUSE_RESTORE_FAILED" \
        "Auto-Restore Failed" \
        "Lighthouse confirmed site healthy but auto-restore failed. Manual intervention needed." \
        "error" "$DEPLOY_NAMESPACE"
      exit 1
    fi
  else
    log_info "AUTO_DISABLE_MAINTENANCE=NO - manual intervention required"
    log_info "Run: ./openshift/scripts/remove-maintenance-message.sh"

    send_notification "LIGHTHOUSE_READY_FOR_RESTORE" \
      "Site Ready - Waiting for Manual Restore" \
      "Lighthouse confirmed site healthy. Waiting for manual maintenance mode disable." \
        "info" "$DEPLOY_NAMESPACE"
  fi

elif [[ "$site_status" == "degraded" ]]; then
  # Site functional but has warnings
  log_warn "Site is functional but has warnings ($LIGHTHOUSE_WARNINGS)"
  log_warn "Leaving maintenance mode enabled for safety"
  log_info "Manual override:"
  log_info "  ./openshift/scripts/remove-maintenance-message.sh --force"

  send_notification "LIGHTHOUSE_DEGRADED" \
    "Site Degraded - Maintenance Mode Retained" \
    "Lighthouse reports $LIGHTHOUSE_WARNINGS warnings. Site functional but maintenance mode retained. Review warnings before restoring." \
    "warning" "$DEPLOY_NAMESPACE"

else
  # Site is broken/unhealthy
  log_error "Site is unhealthy - maintenance mode MUST remain enabled"
  log_error "DO NOT disable maintenance mode until issues are resolved"
  log_info "Troubleshooting:"
  log_info "  1. Check deployment logs"
  log_info "  2. Verify database health"
  log_info "  3. Check PHP pod logs"
  log_info "  4. Review Lighthouse detailed report"

  send_notification "LIGHTHOUSE_CRITICAL_FAILURE" \
    "🚨 Site Broken - Maintenance Mode Active" \
    "Lighthouse reports critical failure. Site inaccessible or broken. Maintenance mode retained. URGENT: Investigate immediately!" \
    "error" "$DEPLOY_NAMESPACE"

  exit 1
fi

echo ""
log_success "Lighthouse completion handler finished successfully"
