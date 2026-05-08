#!/bin/bash
# =============================================================================
# galera-recover.sh - Recover Galera Cluster from Split-Brain
# =============================================================================
# Purpose: Force bootstrap from most advanced node to recover quorum
#          Designed to run inside an OpenShift pod with oc CLI access
#
# Usage:
#   # Interactive (with confirmation):
#   oc exec -it deployment/pod-health-monitor -n <namespace> -- /scripts/utils/galera-recover.sh
#
#   # Force mode (skip confirmation):
#   oc exec deployment/pod-health-monitor -n <namespace> -- /scripts/utils/galera-recover.sh --force
#
# Prerequisites: DB_ROOT_PASSWORD environment variable must be set
# =============================================================================

set -euo pipefail

# Configuration
NAMESPACE="${DEPLOY_NAMESPACE:-$(oc project -q)}"
STATEFULSET="${DB_DEPLOYMENT_NAME:-mariadb-galera}"
DB_PASSWORD="${DB_ROOT_PASSWORD:-}"
FORCE_MODE=false

# Parse arguments
if [ "${1:-}" = "--force" ]; then
  FORCE_MODE=true
fi

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

log_critical() { echo -e "${RED}$1${NC}"; }
log_warning() { echo -e "${YELLOW}$1${NC}"; }
log_success() { echo -e "${GREEN}$1${NC}"; }
log_info() { echo -e "${CYAN}$1${NC}"; }
log_muted() { echo -e "${GRAY}$1${NC}"; }

section() {
  echo ""
  echo "======================================================================"
  echo "  $1"
  echo "======================================================================"
}

# Prerequisites
if [ -z "$DB_PASSWORD" ]; then
  log_critical "ERROR: DB_ROOT_PASSWORD environment variable not set"
  exit 1
fi

section "GALERA CLUSTER RECOVERY"

log_info "Target namespace: $NAMESPACE"
log_info "StatefulSet: $STATEFULSET"

# Step 1: Get running pods
PODS=$(oc get pods -l "app.kubernetes.io/name=$STATEFULSET" -n "$NAMESPACE" \
  --field-selector=status.phase=Running \
  -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$PODS" ]; then
  log_critical "ERROR: No running pods found"
  log_info "Check pod status: oc get pods -l app.kubernetes.io/name=$STATEFULSET -n $NAMESPACE"
  exit 1
fi

log_success "Found running pods: $PODS"

# Step 2: Find most advanced node
section "ANALYZING NODE STATES"

BEST_POD=""
MAX_SEQNO=-1

for POD in $PODS; do
  GRASTATE=$(oc exec "$POD" -n "$NAMESPACE" -- cat /bitnami/mariadb/data/grastate.dat 2>/dev/null || echo "")

  if [ -z "$GRASTATE" ]; then
    log_warning "$POD: grastate.dat unavailable"
    continue
  fi

  SEQNO=$(echo "$GRASTATE" | grep "^seqno:" | awk '{print $2}')
  SAFE=$(echo "$GRASTATE" | grep "^safe_to_bootstrap:" | awk '{print $2}')

  log_muted "  $POD: seqno=$SEQNO, safe_to_bootstrap=$SAFE"

  # Find highest seqno (excluding -1)
  if [ "$SEQNO" != "-1" ] && [ "$SEQNO" -gt "$MAX_SEQNO" ]; then
    MAX_SEQNO=$SEQNO
    BEST_POD=$POD
  fi
done

# If all nodes have seqno=-1, use first pod
if [ -z "$BEST_POD" ]; then
  BEST_POD=$(echo "$PODS" | awk '{print $1}')
  log_warning "All nodes have seqno=-1 (unclean shutdown)"
  log_warning "Using first pod: $BEST_POD"
else
  log_success "Most advanced node: $BEST_POD (seqno: $MAX_SEQNO)"
fi

# Step 3: Confirmation
if [ "$FORCE_MODE" = false ]; then
  echo ""
  log_warning "RECOVERY PLAN:"
  log_muted "  Namespace:       $NAMESPACE"
  log_muted "  Bootstrap Node:  $BEST_POD"
  log_muted "  Action:          Force pc.bootstrap=YES"
  echo ""
  read -p "Proceed with recovery? (yes/no): " CONFIRM

  if [ "$CONFIRM" != "yes" ]; then
    log_warning "Recovery cancelled"
    exit 0
  fi
fi

# Step 4: Set safe_to_bootstrap if needed
section "PREPARING BOOTSTRAP NODE"

SAFE=$(oc exec "$BEST_POD" -n "$NAMESPACE" -- cat /bitnami/mariadb/data/grastate.dat 2>/dev/null \
  | grep "^safe_to_bootstrap:" | awk '{print $2}')

if [ "$SAFE" = "0" ]; then
  log_info "Setting safe_to_bootstrap=1 on $BEST_POD..."
  oc exec "$BEST_POD" -n "$NAMESPACE" -- bash -c \
    "sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /bitnami/mariadb/data/grastate.dat"

  log_info "Restarting $BEST_POD to apply flag..."
  oc delete pod "$BEST_POD" -n "$NAMESPACE"

  # Wait for pod to restart
  log_info "Waiting for pod restart..."
  sleep 15

  for i in {1..60}; do
    PHASE=$(oc get pod "$BEST_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [ "$PHASE" = "Running" ]; then
      sleep 10  # Extra time for MySQL to start
      log_success "Pod restarted and running"
      break
    fi
    sleep 5
  done
fi

# Step 5: Bootstrap cluster
section "BOOTSTRAPPING CLUSTER"

log_info "Executing bootstrap command..."
oc exec "$BEST_POD" -n "$NAMESPACE" -- mysql -uroot -p"$DB_PASSWORD" \
  -e "SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';" 2>/dev/null

if [ $? -eq 0 ]; then
  log_success "✓ Bootstrap command executed"
else
  log_critical "✗ Bootstrap command failed"
  exit 1
fi

sleep 5

# Step 6: Verify primary status
CLUSTER_STATUS=$(oc exec "$BEST_POD" -n "$NAMESPACE" -- mysql -uroot -p"$DB_PASSWORD" -sN \
  -e "SHOW STATUS LIKE 'wsrep_cluster_status';" 2>/dev/null | awk '{print $2}')

if [ "$CLUSTER_STATUS" = "Primary" ]; then
  log_success "✓ Bootstrap node is PRIMARY"
else
  log_critical "✗ Bootstrap node not in Primary state (status: $CLUSTER_STATUS)"
  exit 1
fi

# Step 7: Wait for cluster formation
section "CLUSTER FORMATION"

log_info "Waiting for other nodes to rejoin..."

for i in {1..60}; do
  CLUSTER_SIZE=$(oc exec "$BEST_POD" -n "$NAMESPACE" -- mysql -uroot -p"$DB_PASSWORD" -sN \
    -e "SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null | awk '{print $2}')

  echo "  [$i/60] Cluster Size: $CLUSTER_SIZE"

  # Check if we've reached expected size (can't auto-detect, so just monitor)
  sleep 5
done

# Step 8: Final status
section "RECOVERY COMPLETE"

FINAL_STATUS=$(oc exec "$BEST_POD" -n "$NAMESPACE" -- mysql -uroot -p"$DB_PASSWORD" -sN \
  -e "SHOW STATUS LIKE 'wsrep_cluster_status'; SHOW STATUS LIKE 'wsrep_cluster_size';" 2>/dev/null)

read -r STATUS_LABEL STATUS_VALUE SIZE_LABEL SIZE_VALUE <<< "$FINAL_STATUS"

log_success "Cluster Status: $STATUS_VALUE"
log_success "Cluster Size:   $SIZE_VALUE"

echo ""
log_info "Next steps:"
log_muted "  1. Verify all pods healthy: oc get pods -l app.kubernetes.io/name=$STATEFULSET -n $NAMESPACE"
log_muted "  2. Check application connectivity"
log_muted "  3. If not done, deploy timeout fix to prevent recurrence"
echo ""
