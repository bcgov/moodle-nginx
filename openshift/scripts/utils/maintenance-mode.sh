#!/bin/bash
# =============================================================================
# Emergency Maintenance Mode
# =============================================================================
# Enables Moodle and/or OpenShift maintenance mode in response to a critical
# audit failure. Used as a circuit-breaker when Lighthouse detects the site
# is broken after deployment.
#
# Supports two independent modes:
#   - Moodle maintenance: Runs PHP CLI in the cron pod
#   - OpenShift maintenance: Redirects routes to a static maintenance page
#
# Usage:
#   source openshift/scripts/utils/maintenance-mode.sh
#   enable_emergency_maintenance <namespace> <oc_token> <oc_server> \
#                                <moodle_maintenance> <openshift_maintenance> \
#                                [cron_app_label]
#
# Parameters:
#   namespace             — OpenShift project/namespace
#   oc_token              — Service account auth token
#   oc_server             — API server URL
#   moodle_maintenance    — "YES" to enable Moodle maintenance mode
#   openshift_maintenance — "YES" to enable OpenShift route redirect
#   cron_app_label        — app label for cron pod selector (default: moodle-cron)
#
# See: .docs/diagrams/build-deployment-flow.md
# =============================================================================

enable_emergency_maintenance() {
  local namespace="${1:?Usage: enable_emergency_maintenance <namespace> <token> <server> <moodle_maint> <os_maint> [cron_label]}"
  local oc_token="${2:?Missing oc_token}"
  local oc_server="${3:-https://api.silver.devops.gov.bc.ca:6443}"
  local moodle_maintenance="${4:-NO}"
  local openshift_maintenance="${5:-NO}"
  local cron_app_label="${6:-moodle-cron}"

  echo "🚨 Lighthouse audit FAILED — evaluating maintenance mode response"
  echo "  Environment: $namespace"
  echo "  Moodle maintenance:    $moodle_maintenance"
  echo "  OpenShift maintenance: $openshift_maintenance"
  echo ""

  # ── Install oc CLI if not present ──
  if ! command -v oc &>/dev/null; then
    curl -sSL --connect-timeout 15 --max-time 60 \
      https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
      | tar xz 2>/dev/null
    if [ -f "./oc" ]; then
      sudo mv oc kubectl /usr/local/bin/ 2>/dev/null || sudo mv oc /usr/local/bin/
    else
      echo "⚠️ Failed to download oc CLI — cannot enable maintenance mode"
      return 1
    fi
  fi
  echo "oc version: $(oc version --client 2>/dev/null || echo 'installed')"

  # ── Login to OpenShift ──
  oc login --token="$oc_token" \
    --server="$oc_server" \
    --insecure-skip-tls-verify=true \
    --request-timeout=30s 2>&1 | grep -v '^Warning:'
  oc project "$namespace" 2>/dev/null || true

  # ── Moodle maintenance mode (PHP CLI in cron pod) ──
  if [ "$moodle_maintenance" = "YES" ]; then
    echo ""
    echo "🔧 Enabling Moodle maintenance mode..."
    local cron_pod
    cron_pod=$(oc get pods -l "app=$cron_app_label" \
      --field-selector=status.phase=Running \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -n "$cron_pod" ]; then
      if oc exec -n "$namespace" "$cron_pod" -- \
           php /var/www/html/admin/cli/maintenance.php --enable 2>&1; then
        echo "✅ Moodle maintenance mode enabled"
      else
        echo "⚠️ Failed to enable Moodle maintenance mode (non-fatal)"
      fi
    else
      echo "⚠️ No running cron pod found — cannot enable Moodle maintenance mode"
    fi
  fi

  # ── OpenShift maintenance mode (route redirect to static page) ──
  if [ "$openshift_maintenance" = "YES" ]; then
    echo ""
    echo "🚧 Enabling OpenShift maintenance mode..."

    if oc get deployment maintenance-message -n "$namespace" &>/dev/null; then
      # Scale up maintenance page
      oc scale deployment/maintenance-message -n "$namespace" --replicas=1
      oc rollout status deployment/maintenance-message -n "$namespace" --timeout=120s 2>/dev/null || true

      # Redirect all routes to maintenance page
      local routes route
      routes=$(oc get routes -n "$namespace" -o jsonpath='{.items[*].metadata.name}')
      for route in $routes; do
        if oc patch route "$route" -n "$namespace" \
             -p '{"spec":{"to":{"name":"maintenance-message"}}}' 2>/dev/null; then
          echo "  ✅ Patched route: $route → maintenance-message"
        else
          echo "  ⚠️ Failed to patch route: $route"
        fi
      done

      echo "✅ OpenShift maintenance mode enabled — traffic redirected to maintenance page"
    else
      echo "⚠️ maintenance-message deployment not found — skipping OpenShift maintenance mode"
      echo "  Ensure deploy-maintenance-message.sh has been run for this environment"
    fi
  fi

  # ── Manual remediation instructions ──
  echo ""
  echo "══════════════════════════════════════════════════"
  echo "🚨 MANUAL ACTION REQUIRED"
  echo "══════════════════════════════════════════════════"
  echo "Investigate and resolve the Lighthouse audit failure, then disable maintenance mode:"
  if [ "$moodle_maintenance" = "YES" ]; then
    echo "  Moodle:    oc exec <cron-pod> -- php /var/www/html/admin/cli/maintenance.php --disable"
  fi
  if [ "$openshift_maintenance" = "YES" ]; then
    echo "  OpenShift: Redeploy, or manually patch routes back to 'web' service:"
    echo "             oc patch route <route-name> -p '{\"spec\":{\"to\":{\"name\":\"web\"}}}'"
  fi
}
