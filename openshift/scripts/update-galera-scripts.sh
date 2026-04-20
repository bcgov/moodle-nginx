#!/bin/bash
# =============================================================================
# UPDATE GALERA RECOVERY SCRIPTS
# =============================================================================
# Purpose: Deploy/update Galera diagnostic and recovery scripts to pod-health-monitor
#          Updates ConfigMap and restarts monitoring pod for immediate availability
#
# Usage:
#   # Update scripts in current namespace
#   bash ./update-galera-scripts.sh
#
#   # Update scripts in specific namespace
#   export DEPLOY_NAMESPACE=950003-prod
#   bash ./update-galera-scripts.sh
#
#   # Or with inline namespace
#   DEPLOY_NAMESPACE=950003-dev bash ./update-galera-scripts.sh
#
# What This Script Does:
#   1. Creates/updates ConfigMap with galera-inspect.sh and galera-recover.sh
#   2. Restarts pod-health-monitor deployment to mount updated scripts
#   3. Validates scripts are accessible inside the pod
#   4. Provides usage examples for recovery operations
#
# Scripts Deployed:
#   /scripts/galera-inspect.sh  - Cluster health diagnostics
#   /scripts/galera-recover.sh  - Automated split-brain recovery
#
# Related Documentation:
#   - Recovery scripts: ./galera-inspect.sh, ./galera-recover.sh
#   - RCA: ../../docs/galera-split-brain-rca.md
#   - Manual override: ../../docs/manual-mode-override.md
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
CONFIGMAP_NAME="galera-recovery-scripts"
DEPLOYMENT_NAME="pod-health-monitor"

# Auto-detect namespace if not set
if [[ -z "$DEPLOY_NAMESPACE" ]]; then
  DEPLOY_NAMESPACE=$(oc project -q 2>/dev/null || echo "")
  if [[ -z "$DEPLOY_NAMESPACE" ]]; then
    log_error "DEPLOY_NAMESPACE not set and no active OpenShift project"
    echo "Usage: DEPLOY_NAMESPACE=950003-prod bash $0"
    exit 1
  fi
  log_warning "Using current project: $DEPLOY_NAMESPACE"
fi

log_info "🔧 Updating Galera recovery scripts in namespace: $DEPLOY_NAMESPACE"

# Validate scripts exist
if [[ ! -f "${SCRIPT_DIR}/galera-inspect.sh" ]]; then
  log_error "galera-inspect.sh not found in ${SCRIPT_DIR}"
  exit 1
fi

if [[ ! -f "${SCRIPT_DIR}/galera-recover.sh" ]]; then
  log_error "galera-recover.sh not found in ${SCRIPT_DIR}"
  exit 1
fi

# Step 1: Create or update ConfigMap
log_info "📦 Creating/updating ConfigMap: $CONFIGMAP_NAME"

if oc get configmap "$CONFIGMAP_NAME" -n "$DEPLOY_NAMESPACE" >/dev/null 2>&1; then
  log_info "ConfigMap exists, deleting for clean update..."
  oc delete configmap "$CONFIGMAP_NAME" -n "$DEPLOY_NAMESPACE"
fi

# Create ConfigMap from script files
oc create configmap "$CONFIGMAP_NAME" \
  -n "$DEPLOY_NAMESPACE" \
  --from-file=galera-inspect.sh="${SCRIPT_DIR}/galera-inspect.sh" \
  --from-file=galera-recover.sh="${SCRIPT_DIR}/galera-recover.sh"

# Label ConfigMap for tracking
oc label configmap "$CONFIGMAP_NAME" \
  -n "$DEPLOY_NAMESPACE" \
  app.kubernetes.io/component=monitoring \
  app.kubernetes.io/part-of=galera-recovery \
  --overwrite

log_success "✓ ConfigMap updated: $CONFIGMAP_NAME"

# Step 2: Check if pod-health-monitor deployment exists
if ! oc get deployment "$DEPLOYMENT_NAME" -n "$DEPLOY_NAMESPACE" >/dev/null 2>&1; then
  log_warning "Deployment '$DEPLOYMENT_NAME' not found in namespace '$DEPLOY_NAMESPACE'"
  log_info "ConfigMap created, but no deployment to restart"
  log_info "Deploy pod-health-monitor first: bash ./deploy-health-monitor.sh"
  exit 0
fi

# Step 3: Patch deployment to mount the ConfigMap
log_info "🔧 Patching deployment to mount recovery scripts..."

# Check if volume already exists
EXISTING_VOLUMES=$(oc get deployment "$DEPLOYMENT_NAME" -n "$DEPLOY_NAMESPACE" \
  -o jsonpath='{.spec.template.spec.volumes[*].name}' 2>/dev/null || echo "")

if echo "$EXISTING_VOLUMES" | grep -q "galera-recovery-scripts"; then
  log_info "Volume mount already configured, triggering restart..."
else
  log_info "Adding volume mount configuration..."

  # Add volume to deployment
  oc patch deployment "$DEPLOYMENT_NAME" \
    -n "$DEPLOY_NAMESPACE" \
    --type=json \
    -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/volumes/-",
        "value": {
          "name": "galera-recovery-scripts",
          "configMap": {
            "name": "'"$CONFIGMAP_NAME"'",
            "defaultMode": 493
          }
        }
      }
    ]'

  # Add volumeMount to container
  oc patch deployment "$DEPLOYMENT_NAME" \
    -n "$DEPLOY_NAMESPACE" \
    --type=json \
    -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/containers/0/volumeMounts/-",
        "value": {
          "name": "galera-recovery-scripts",
          "mountPath": "/scripts/galera"
        }
      }
    ]'
fi

# Step 4: Trigger restart to mount updated scripts
log_info "🔄 Restarting pod-health-monitor to apply updates..."

oc rollout restart deployment/"$DEPLOYMENT_NAME" -n "$DEPLOY_NAMESPACE"
oc rollout status deployment/"$DEPLOYMENT_NAME" -n "$DEPLOY_NAMESPACE" --timeout=120s

log_success "✓ Deployment restarted successfully"

# Step 5: Validate scripts are accessible
log_info "✅ Validating script accessibility..."

POD_NAME=$(oc get pods -l app=pod-health-monitor -n "$DEPLOY_NAMESPACE" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$POD_NAME" ]]; then
  log_warning "Could not find running pod for validation"
else
  # Check if scripts exist and are executable
  if oc exec "$POD_NAME" -n "$DEPLOY_NAMESPACE" -- test -x /scripts/galera/galera-inspect.sh 2>/dev/null; then
    log_success "✓ galera-inspect.sh is accessible and executable"
  else
    log_warning "⚠ galera-inspect.sh may not be accessible"
  fi

  if oc exec "$POD_NAME" -n "$DEPLOY_NAMESPACE" -- test -x /scripts/galera/galera-recover.sh 2>/dev/null; then
    log_success "✓ galera-recover.sh is accessible and executable"
  else
    log_warning "⚠ galera-recover.sh may not be accessible"
  fi
fi

# Step 6: Provide usage examples
cat <<EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

$(log_success "✓ Galera recovery scripts deployed successfully!")

$(log_info "📖 Usage Examples:")

$(log_muted "# Inspect cluster health (diagnose split-brain)")
oc exec -it deployment/pod-health-monitor -n $DEPLOY_NAMESPACE -- bash /scripts/galera/galera-inspect.sh

$(log_muted "# Recover from split-brain (interactive mode with confirmation)")
oc exec -it deployment/pod-health-monitor -n $DEPLOY_NAMESPACE -- bash /scripts/galera/galera-recover.sh

$(log_muted "# Force recovery (no confirmation, for automation)")
oc exec deployment/pod-health-monitor -n $DEPLOY_NAMESPACE -- bash /scripts/galera/galera-recover.sh --force

$(log_info "💡 Tips:")
- Use $(log_muted "galera-inspect.sh") first to diagnose cluster status
- Enable MANUAL_MODE before recovery to prevent automation interference:
  $(log_muted "oc set env deployment/pod-health-monitor MANUAL_MODE=true -n $DEPLOY_NAMESPACE")
- Re-enable after recovery:
  $(log_muted "oc set env deployment/pod-health-monitor MANUAL_MODE=false -n $DEPLOY_NAMESPACE")

$(log_info "📚 Documentation:")
- Root cause analysis: $(log_muted "docs/galera-split-brain-rca.md")
- Manual override guide: $(log_muted "docs/manual-mode-override.md")
- Timeout configuration: $(log_muted "docs/galera-timeout-quickstart.md")

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

EOF

log_success "✓ Update complete!"
