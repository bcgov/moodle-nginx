#!/usr/bin/env bash
#===============================================================================
# Safe Galera StatefulSet Scaling Wrapper
#===============================================================================
# Provides a safe interface for manual Galera cluster scaling operations.
# Wraps `oc scale` commands with Galera-specific protections:
#   - Pre-flight cluster address verification
#   - Incremental scale-up with sync validation
#   - Split-brain prevention
#   - Comprehensive health checks
#
# USAGE:
#   ./scripts/scale-galera.sh <sts-name> --replicas=<N>
#   ./scripts/scale-galera.sh mariadb-galera --replicas=5
#
# PARAMETERS:
#   sts-name: Name of the Galera StatefulSet (e.g., "mariadb-galera")
#   --replicas: Target replica count
#
# ENVIRONMENT VARIABLES:
#   DEPLOY_NAMESPACE: Target Kubernetes namespace (default: current context)
#
# RELATED:
#   - docs/galera-deployment-best-practices.md#solution-5
#   - openshift/scripts/utils/openshift.sh (scale_galera_statefulset)
#
# NEVER USE THESE COMMANDS DIRECTLY:
#   ❌ oc scale sts/mariadb-galera --replicas=5
#   ❌ oc delete pod mariadb-galera-{1,2,3,4}
#   ❌ oc delete pvc data-mariadb-galera-*
#   ❌ oc rollout restart sts/mariadb-galera
#
# ALWAYS USE:
#   ✅ ./scripts/scale-galera.sh mariadb-galera --replicas=5
#   ✅ ./scripts/bootstrap-mariadb-galera.ps1 -Bootstrap
#===============================================================================

set -euo pipefail

#===============================================================================
# Configuration
#===============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UTILS_DIR="$REPO_ROOT/openshift/scripts/utils"

# Source utilities
if [[ -f "$UTILS_DIR/_utils.sh" ]]; then
  source "$UTILS_DIR/_utils.sh"
else
  echo "❌ ERROR: Cannot find _utils.sh at $UTILS_DIR/_utils.sh"
  exit 1
fi

if [[ -f "$UTILS_DIR/openshift.sh" ]]; then
  source "$UTILS_DIR/openshift.sh"
else
  echo "❌ ERROR: Cannot find openshift.sh at $UTILS_DIR/openshift.sh"
  exit 1
fi

# Defaults
DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE:-$(oc project -q 2>/dev/null || echo "default")}"

#===============================================================================
# Parse Arguments
#===============================================================================
show_usage() {
  cat << EOF
USAGE:
  $(basename "$0") <sts-name> --replicas=<N> [--namespace=<ns>]

EXAMPLES:
  # Scale mariadb-galera to 5 replicas in current namespace
  $(basename "$0") mariadb-galera --replicas=5

  # Scale mariadb-galera to 3 replicas in specific namespace
  $(basename "$0") mariadb-galera --replicas=3 --namespace=e66ac2-prod

PARAMETERS:
  sts-name        Name of the Galera StatefulSet
  --replicas=N    Target replica count
  --namespace=NS  Target Kubernetes namespace (optional)

ENVIRONMENT:
  DEPLOY_NAMESPACE  Default namespace if --namespace not specified

SAFETY:
  This wrapper provides Galera-specific protections that prevent split-brain:
  ✅ Pre-flight cluster address verification
  ✅ Incremental scale-up (1→2→3→...→N) with sync validation
  ✅ Split-brain detection and prevention
  ✅ Comprehensive health checks

NEVER use 'oc scale' directly for Galera clusters!
See: docs/galera-deployment-best-practices.md
EOF
  exit 0
}

if [[ $# -lt 2 ]]; then
  echo "❌ ERROR: Missing required arguments"
  echo ""
  show_usage
fi

# Parse positional and named arguments
STS_NAME="$1"
shift

TARGET_REPLICAS=""
NAMESPACE="$DEPLOY_NAMESPACE"

for arg in "$@"; do
  case "$arg" in
    --replicas=*)
      TARGET_REPLICAS="${arg#*=}"
      ;;
    --namespace=*)
      NAMESPACE="${arg#*=}"
      ;;
    --help|-h)
      show_usage
      ;;
    *)
      echo "❌ ERROR: Unknown argument: $arg"
      show_usage
      ;;
  esac
done

# Validate required parameters
if [[ -z "$TARGET_REPLICAS" ]]; then
  echo "❌ ERROR: --replicas parameter is required"
  show_usage
fi

if ! [[ "$TARGET_REPLICAS" =~ ^[0-9]+$ ]]; then
  echo "❌ ERROR: --replicas must be a positive integer, got: $TARGET_REPLICAS"
  exit 1
fi

#===============================================================================
# Validation
#===============================================================================
log_header "Galera Safe Scaling: $STS_NAME"

# Check if StatefulSet exists
if ! oc get sts/"$STS_NAME" -n "$NAMESPACE" &>/dev/null; then
  log_error "StatefulSet not found: $STS_NAME in namespace $NAMESPACE"
  exit 1
fi

# Verify this is actually a Galera cluster
if [[ "$STS_NAME" != *"galera"* ]]; then
  log_warn "⚠️  WARNING: This StatefulSet name doesn't contain 'galera'"
  log_warn "    Are you sure this is a Galera cluster?"
  log_warn "    StatefulSet: $STS_NAME"
  echo ""
  read -p "Continue anyway? (yes/no): " confirm
  if [[ "$confirm" != "yes" ]]; then
    log_info "Operation cancelled by user"
    exit 0
  fi
fi

# Get current replica count
CURRENT_REPLICAS=$(oc get sts/"$STS_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}')

log_info "Current replicas: $CURRENT_REPLICAS"
log_info "Target replicas:  $TARGET_REPLICAS"
log_info "Namespace:        $NAMESPACE"

if [[ "$CURRENT_REPLICAS" -eq "$TARGET_REPLICAS" ]]; then
  log_success "Already at target replica count ($TARGET_REPLICAS)"
  exit 0
fi

echo ""
log_warn "⚠️  This operation will scale the Galera cluster:"
if [[ "$CURRENT_REPLICAS" -lt "$TARGET_REPLICAS" ]]; then
  log_warn "    📈 Scale-up: $CURRENT_REPLICAS → $TARGET_REPLICAS replicas"
  log_warn "    This will add nodes incrementally with sync validation"
else
  log_warn "    📉 Scale-down: $CURRENT_REPLICAS → $TARGET_REPLICAS replicas"
  log_warn "    Nodes will be removed in reverse order (pod-N → ... → pod-$TARGET_REPLICAS)"
fi
echo ""

read -p "Proceed with scaling? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
  log_info "Operation cancelled by user"
  exit 0
fi

#===============================================================================
# Execute Galera-Aware Scaling
#===============================================================================
echo ""
log_header "Executing Safe Galera Scaling"

# Call the Galera-aware scaling function from openshift.sh
if scale_galera_statefulset "$STS_NAME" "$TARGET_REPLICAS" "$NAMESPACE"; then
  echo ""
  log_success "✅ Galera cluster scaled successfully!"
  log_success "   StatefulSet: $STS_NAME"
  log_success "   Replicas:    $CURRENT_REPLICAS → $TARGET_REPLICAS"
  log_success "   Namespace:   $NAMESPACE"
  exit 0
else
  echo ""
  log_error "❌ Galera scaling operation failed!"
  log_error "   StatefulSet: $STS_NAME"
  log_error "   Target:      $TARGET_REPLICAS replicas"
  log_error "   Namespace:   $NAMESPACE"
  echo ""
  log_error "Troubleshooting:"
  log_error "  1. Check cluster health:"
  log_error "     oc exec ${STS_NAME}-0 -n $NAMESPACE -- mysql -e 'SHOW STATUS LIKE \"wsrep%\"'"
  echo ""
  log_error "  2. Check cluster address:"
  log_error "     oc exec ${STS_NAME}-0 -n $NAMESPACE -- env | grep MARIADB_GALERA_CLUSTER_ADDRESS"
  echo ""
  log_error "  3. Check pod logs for errors:"
  log_error "     oc logs ${STS_NAME}-0 -n $NAMESPACE --tail=50"
  echo ""
  log_error "  4. Run bootstrap recovery:"
  log_error "     ./scripts/bootstrap-mariadb-galera.ps1 -Bootstrap"
  echo ""
  log_error "See: docs/manual-galera-troubleshooting.md"
  exit 1
fi
