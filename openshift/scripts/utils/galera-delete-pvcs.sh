#!/bin/bash
# =============================================================================
# GALERA PVC DELETION UTILITY
# =============================================================================
# DANGER: Permanently deletes PVCs for Galera nodes.
# This causes IRREVERSIBLE DATA LOSS on those nodes.
#
# ⚠️  WARNING: Only use this utility when:
#   1. You are CERTAIN pod-0 has the latest/correct data
#   2. Other nodes have corrupted/invalid data
#   3. You want to force fresh SST (State Snapshot Transfer) from pod-0
#
# Typical use case: After fixing split-brain, delete PVCs 1-4 to force
# them to resync from pod-0 rather than trying to rejoin with stale data.
#
# Usage (Interactive - requires confirmation):
#   oc exec deployment/pod-health-monitor -n <namespace> -- \
#     /scripts/utils/galera-delete-pvcs.sh --namespace=<ns>
#
# Usage (Non-Interactive - for automation):
#   /scripts/utils/galera-delete-pvcs.sh \
#     --non-interactive \
#     --namespace=<ns> \
#     --keep-node=0 \
#     --force
#
# Flags:
#   --non-interactive       Skip prompts
#   --namespace=<ns>        Target namespace (required)
#   --statefulset=<name>    StatefulSet name (default: mariadb-galera)
#   --keep-node=<num>       Node to keep (default: 0), deletes all others
#   --delete-nodes=<list>   Specific nodes to delete (comma-separated, e.g., "1,2,3")
#   --force                 Skip confirmation
#
# Returns:
#   0 = success
#   1 = failure
# =============================================================================

set -euo pipefail

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_galera_utils.sh"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

NAMESPACE=""
STATEFULSET="mariadb-galera"
KEEP_NODE=0
DELETE_NODES=""
FORCE=false
NON_INTERACTIVE=false

print_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

⚠️  DANGER: Permanently deletes Galera PVCs (IRREVERSIBLE DATA LOSS)

OPTIONS:
  --non-interactive          Skip prompts
  --namespace=<ns>           Target namespace (REQUIRED)
  --statefulset=<name>       StatefulSet name (default: mariadb-galera)
  --keep-node=<num>          Node to keep (default: 0), deletes all others
  --delete-nodes=<list>      Specific nodes to delete (comma-separated)
  --force                    Skip confirmation
  -h, --help                 Show this help message

EXAMPLES:
  # Delete PVCs for nodes 1-4, keep node 0
  $0 --namespace=950003-prod --keep-node=0

  # Delete specific nodes
  $0 --namespace=950003-prod --delete-nodes=1,2,3

  # Non-interactive mode (for automation)
  $0 --non-interactive --namespace=950003-prod --keep-node=0 --force

EXIT CODES:
  0 = Success
  1 = Failure
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --non-interactive)
      NON_INTERACTIVE=true
      export NON_INTERACTIVE
      shift
      ;;
    --namespace=*)
      NAMESPACE="${1#*=}"
      shift
      ;;
    --statefulset=*)
      STATEFULSET="${1#*=}"
      shift
      ;;
    --keep-node=*)
      KEEP_NODE="${1#*=}"
      shift
      ;;
    --delete-nodes=*)
      DELETE_NODES="${1#*=}"
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      log_critical "Unknown option: $1"
      print_usage
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$NAMESPACE" ]]; then
  log_critical "ERROR: --namespace is required"
  echo ""
  print_usage
  exit 1
fi

# =============================================================================
# MAIN EXECUTION
# =============================================================================

section "GALERA PVC DELETION UTILITY"

log_info "Namespace: $NAMESPACE"
log_info "StatefulSet: $STATEFULSET"
echo ""

# Setup authentication
galera_setup_auth

# Determine which PVCs to delete
declare -a pvcs_to_delete

if [[ -n "$DELETE_NODES" ]]; then
  # Specific nodes
  log_info "Deleting specific nodes: $DELETE_NODES"
  IFS=',' read -ra nodes <<< "$DELETE_NODES"
  for node in "${nodes[@]}"; do
    pvcs_to_delete+=("data-$STATEFULSET-$node")
  done
else
  # All nodes except keep-node
  log_info "Deleting all nodes except: $KEEP_NODE"

  # Get total replicas
  local total_replicas
  total_replicas=$(galera_get_target_replicas "$NAMESPACE" "$STATEFULSET")

  for i in $(seq 0 $((total_replicas - 1))); do
    if [[ $i -ne $KEEP_NODE ]]; then
      pvcs_to_delete+=("data-$STATEFULSET-$i")
    fi
  done
fi

# Display what will be deleted
section "⚠️  WARNING: IRREVERSIBLE DATA LOSS"
echo ""
log_critical "The following PVCs will be PERMANENTLY DELETED:"
for pvc in "${pvcs_to_delete[@]}"; do
  echo "  • $pvc"
done
echo ""
log_critical "This action CANNOT be undone!"
log_critical "All data on these volumes will be lost!"
echo ""

# Confirmation
if [[ "$FORCE" != "true" ]] && ! is_non_interactive; then
  if ! prompt_confirm "Type 'DELETE-PVCS' to confirm permanent deletion:" "DELETE-PVCS"; then
    log_info "Deletion cancelled"
    exit 0
  fi
  echo ""
fi

# Delete PVCs
section "DELETING PVCs"

for pvc in "${pvcs_to_delete[@]}"; do
  log_info "Deleting $pvc..."

  if oc delete pvc "$pvc" -n "$NAMESPACE" --ignore-not-found=true >/dev/null 2>&1; then
    log_success "  ✓ Deleted $pvc"
  else
    log_warning "  ⚠ Could not delete $pvc (may not exist)"
  fi
done

echo ""
section "DELETION COMPLETE"
log_success "Deleted ${#pvcs_to_delete[@]} PVC(s)"
echo ""
log_info "Next steps:"
log_muted "  • Scale StatefulSet up to recreate pods"
log_muted "  • New pods will perform fresh SST from node $KEEP_NODE"
log_muted "  • Monitor: oc get pods -l app.kubernetes.io/name=$STATEFULSET -n $NAMESPACE"
echo ""

exit 0
#!/bin/bash
# =============================================================================
# galera-delete-pvcs.sh - Delete Galera PVCs (DANGEROUS - Data Loss)
# =============================================================================
# Purpose: Delete PVCs for specific Galera nodes (PERMANENT DATA LOSS)
#
# WARNING: This is a DESTRUCTIVE operation. Only use when:
#   - You're certain the bootstrap node (usually pod-0) has all the data
#   - Other nodes have corrupted/conflicting data that cannot be resynced
#   - You understand this will PERMANENTLY delete data on those nodes
#
# Usage:
#   # Delete PVCs 1-4 (keep pod-0)
#   ./galera-delete-pvcs.sh --namespace 950003-prod --nodes 1,2,3,4
#
#   # Delete specific PVC
#   ./galera-delete-pvcs.sh --namespace 950003-prod --nodes 2
#
#   # Force mode (skip confirmation)
#   ./galera-delete-pvcs.sh --namespace 950003-prod --nodes 1,2,3,4 --force
#
# Arguments:
#   --namespace <ns>    Required: OpenShift namespace
#   --nodes <list>      Required: Comma-separated node indices to delete (e.g., "1,2,3,4")
#   --force             Optional: Skip confirmation prompts
#
# Returns:
#   0 = success
#   1 = error
#   2 = missing required parameter
# =============================================================================

set -euo pipefail

# Source shared utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_galera_utils.sh"

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

NAMESPACE=""
NODE_INDICES=""
FORCE=false
STS_NAME="mariadb-galera"

usage() {
  cat <<EOF
Delete Galera PVCs (DANGEROUS - PERMANENT DATA LOSS)

Usage:
  $(basename "$0") --namespace <ns> --nodes <list> [OPTIONS]

Required:
  --namespace <ns>    OpenShift namespace
  --nodes <list>      Comma-separated node indices (e.g., "1,2,3,4")

Optional:
  --force             Skip confirmation prompts (DANGEROUS)

Examples:
  # Delete PVCs for nodes 1-4 (keep node 0)
  $(basename "$0") --namespace 950003-prod --nodes 1,2,3,4

  # Delete specific node
  $(basename "$0") --namespace 950003-prod --nodes 2

WARNING:
  This is a DESTRUCTIVE operation that PERMANENTLY deletes data.
  Only use when you're certain the bootstrap node has all necessary data.
  In most cases, fixing cluster address configuration is sufficient.

EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --nodes)
      NODE_INDICES="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    *)
      echo "Unknown argument: $1"
      usage
      ;;
  esac
done

# Validate required arguments
if [[ -z "$NAMESPACE" ]]; then
  log_error "Missing required argument: --namespace"
  usage
fi

if [[ -z "$NODE_INDICES" ]]; then
  log_error "Missing required argument: --nodes"
  usage
fi

# =============================================================================
# PVC DELETION
# =============================================================================

log_warning "⚠️  DANGEROUS OPERATION - PVC DELETION"
echo ""
echo "  Namespace: $NAMESPACE"
echo "  StatefulSet: $STS_NAME"
echo "  Nodes to delete: $NODE_INDICES"
echo ""

# Parse node indices
IFS=',' read -ra NODES <<< "$NODE_INDICES"

echo "  PVCs to delete:"
for node_index in "${NODES[@]}"; do
  echo "    - data-${STS_NAME}-${node_index}"
done
echo ""

log_error "⚠️  THIS WILL PERMANENTLY DELETE DATA ON THESE NODES"
log_error "⚠️  THIS CANNOT BE UNDONE"
echo ""
echo "  Only proceed if:"
echo "    ✓ Bootstrap node (usually pod-0) has all the data"
echo "    ✓ Other nodes have corrupted/conflicting data"
echo "    ✓ You have verified backups exist"
echo ""

if [[ "$FORCE" == "false" ]]; then
  read -p "Type 'DELETE' to confirm PVC deletion (or anything else to cancel): " confirmation

  if [[ "$confirmation" != "DELETE" ]]; then
    log_info "PVC deletion cancelled by user"
    exit 0
  fi

  echo ""
fi

# Setup authentication
galera_setup_auth "$NAMESPACE"

# Delete PVCs
log_info "Deleting PVCs..."
DELETED_COUNT=0
FAILED_COUNT=0

for node_index in "${NODES[@]}"; do
  pvc_name="data-${STS_NAME}-${node_index}"

  log_debug "  Deleting $pvc_name..."

  # Check if PVC exists
  if ! oc get pvc "$pvc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log_warning "    PVC not found, skipping"
    continue
  fi

  # Delete PVC
  if oc delete pvc "$pvc_name" -n "$NAMESPACE" >/dev/null 2>&1; then
    log_success "    Deleted $pvc_name"
    DELETED_COUNT=$((DELETED_COUNT + 1))
  else
    log_error "    Failed to delete $pvc_name"
    FAILED_COUNT=$((FAILED_COUNT + 1))
  fi
done

echo ""
echo "======================================================================"
echo "  PVC DELETION COMPLETE"
echo "======================================================================"
echo ""
echo "  Deleted: $DELETED_COUNT PVC(s)"
echo "  Failed: $FAILED_COUNT PVC(s)"
echo ""

if [[ $FAILED_COUNT -gt 0 ]]; then
  log_warning "Some PVCs failed to delete - check permissions and PVC status"
  exit 1
fi

log_info "Next steps:"
echo "  1. When pods scale up, they will create fresh PVCs"
echo "  2. New nodes will perform SST (State Snapshot Transfer) from bootstrap node"
echo "  3. Monitor sync progress: oc logs <pod-name> -n $NAMESPACE"
echo ""
