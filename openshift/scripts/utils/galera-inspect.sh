#!/bin/bash
# =============================================================================
# galera-inspect.sh - Inspect Galera Cluster Health
# =============================================================================
# Purpose: Diagnose Galera cluster status and detect split-brain conditions
#          Designed to run inside an OpenShift pod with oc CLI access
#
# Usage:
#   # From pod-health-monitor pod (has oc access):
#   oc exec -it deployment/pod-health-monitor -n <namespace> -- /scripts/utils/galera-inspect.sh
#
#   # Or copy to any pod with oc access:
#   oc cp galera-inspect.sh <pod>:/tmp/
#   oc exec <pod> -- bash /tmp/galera-inspect.sh
#
# Output: Cluster health report with recommendations
# =============================================================================

set -euo pipefail

# ============================================================================
# AUTHENTICATION SETUP
# ============================================================================
# When running inside pod-health-monitor, oc may need authentication
# Set writable kubeconfig path (container filesystem root is read-only)
export KUBECONFIG="${KUBECONFIG:-/tmp/.kube/config}"
mkdir -p "$(dirname "$KUBECONFIG")" 2>/dev/null || true

if [[ -n "${OPENSHIFT_TOKEN:-}" && -n "${OPENSHIFT_SERVER:-}" ]]; then
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true >/dev/null 2>&1 || true
fi

# Suppress oc CLI warnings (legacy token, insecure TLS)
export KUBECTL_WARN_EXTERNAL_UNKNOWN=false

# Configuration
NAMESPACE="${DEPLOY_NAMESPACE:-$(oc project -q 2>/dev/null || echo 'default')}"
STATEFULSET="${DB_DEPLOYMENT_NAME:-mariadb-galera}"
DB_USER="${DB_USER:-moodle}"
DB_PASSWORD="${DB_ROOT_PASSWORD:-${DB_PASSWORD:-}}"

# Source utilities if available (for check_galera_cluster_health function)
if [[ -f "/scripts/utils/_utils.sh" ]]; then
  source /scripts/utils/_utils.sh 2>/dev/null || true
fi

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m' # No Color

# Helper functions
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

# =============================================================================
# Main Inspection
# =============================================================================

section "GALERA CLUSTER HEALTH INSPECTOR"

log_info "Target namespace: $NAMESPACE"
log_info "StatefulSet: $STATEFULSET"

# Step 1: Get pod list
section "POD HEALTH STATUS"

PODS=$(oc get pods -l "app.kubernetes.io/name=$STATEFULSET" -n "$NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{" "}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null)

if [ -z "$PODS" ]; then
  log_critical "ERROR: No pods found for StatefulSet '$STATEFULSET'"
  exit 1
fi

RUNNING_PODS=()
CRASHED_PODS=()
NON_PRIMARY_COUNT=0
PRIMARY_COUNT=0

while IFS= read -r line; do
  if [ -z "$line" ]; then continue; fi
  read -r POD_NAME PHASE READY <<< "$line"

  if [ "$PHASE" = "Running" ] && [ "$READY" = "true" ]; then
    log_success "✓ $POD_NAME - Running, Ready"
    RUNNING_PODS+=("$POD_NAME")
  elif [ "$PHASE" = "Running" ]; then
    log_warning "⚠ $POD_NAME - Running, Not Ready"
    RUNNING_PODS+=("$POD_NAME")
  else
    log_critical "✗ $POD_NAME - $PHASE"
    CRASHED_PODS+=("$POD_NAME")
  fi
done <<< "$PODS"

# Step 2: Check timeout configuration FIRST (most critical for split-brain prevention)
if [ ${#RUNNING_PODS[@]} -gt 0 ] && [ -n "$DB_PASSWORD" ]; then
  section "TIMEOUT CONFIGURATION"

  POD="${RUNNING_PODS[0]}"

  # Query full wsrep_provider_options
  PROVIDER_OPTIONS=$(oc exec "$POD" -n "$NAMESPACE" -- \
    mysql -u"$DB_USER" -p"$DB_PASSWORD" -sN \
    -e "SHOW VARIABLES LIKE 'wsrep_provider_options';" 2>/dev/null | tail -1 || echo "")

  if [ -z "$PROVIDER_OPTIONS" ]; then
    log_critical "ERROR: Could not query wsrep_provider_options from $POD"
    log_muted "  Verify DB_PASSWORD is set correctly"
  else
    # Extract key timeout values
    INACTIVE_TIMEOUT=$(echo "$PROVIDER_OPTIONS" | grep -oP 'evs\.inactive_timeout\s*=\s*\K[^;]+' || echo "PT15S (default)")
    SUSPECT_TIMEOUT=$(echo "$PROVIDER_OPTIONS" | grep -oP 'evs\.suspect_timeout\s*=\s*\K[^;]+' || echo "PT5S (default)")
    INACTIVE_CHECK=$(echo "$PROVIDER_OPTIONS" | grep -oP 'evs\.inactive_check_period\s*=\s*\K[^;]+' || echo "PT0.5S (default)")
    KEEPALIVE=$(echo "$PROVIDER_OPTIONS" | grep -oP 'evs\.keepalive_period\s*=\s*\K[^;]+' || echo "PT1S (default)")
    FC_LIMIT=$(echo "$PROVIDER_OPTIONS" | grep -oP 'gcs\.fc_limit\s*=\s*\K[^;]+' || echo "128 (default)")

    log_info "Current Configuration:"
    echo "  evs.inactive_timeout       = $INACTIVE_TIMEOUT  (recommended: PT30S)"
    echo "  evs.suspect_timeout        = $SUSPECT_TIMEOUT  (recommended: PT10S)"
    echo "  evs.inactive_check_period  = $INACTIVE_CHECK  (recommended: PT1S)"
    echo "  evs.keepalive_period       = $KEEPALIVE  (recommended: PT2S)"
    echo "  gcs.fc_limit               = $FC_LIMIT  (recommended: 256)"
    echo ""

    # Determine configuration status
    CONFIG_STATUS="UNKNOWN"
    if [[ "$INACTIVE_TIMEOUT" == "PT30S" && "$SUSPECT_TIMEOUT" == "PT10S" ]]; then
      log_success "STATUS: Using RECOMMENDED production timeouts"
      CONFIG_STATUS="GOOD"
    elif [[ "$INACTIVE_TIMEOUT" =~ PT15S ]]; then
      log_critical "STATUS: Using DEFAULT timeouts - TOO AGGRESSIVE for OpenShift"
      log_warning "  Risk: False-positive split-brain events under network load"
      log_warning "  Action: Deploy timeout fix to prevent recurring split-brain"
      CONFIG_STATUS="CRITICAL"
    else
      log_warning "STATUS: Using CUSTOM timeouts - verify against recommendations"
      CONFIG_STATUS="CUSTOM"
    fi

    # Show deployment command if fix needed
    if [[ "$CONFIG_STATUS" == "CRITICAL" ]]; then
      echo ""
      log_info "Fix deployment command:"
      log_muted "  DEPLOY_NAMESPACE=$NAMESPACE bash openshift/scripts/deploy-mariadb-galera.sh"
      log_muted "  Or use Helm with --set extraFlags (see config/mariadb/galera-timeouts.yaml)"
    fi
  fi
fi

# Step 3: Check cluster status
if [ ${#RUNNING_PODS[@]} -gt 0 ] && [ -n "$DB_PASSWORD" ]; then
  section "CLUSTER STATUS"

  # Use utility function if available
  if declare -f check_galera_cluster_health > /dev/null 2>&1; then
    log_info "Using utility function to check cluster health..."
    check_galera_cluster_health "app.kubernetes.io/name=$STATEFULSET" "$NAMESPACE"
    HEALTH_STATUS=$?

    if [[ $HEALTH_STATUS -eq 0 ]]; then
      log_success "✓ Cluster is healthy (all nodes Primary)"
    elif [[ $HEALTH_STATUS -eq 2 ]]; then
      log_critical "✗ SPLIT-BRAIN DETECTED (multiple cluster UUIDs or all non-Primary)"
    else
      log_warning "⚠ Cluster has issues but may be recoverable"
    fi
  else
    # Fallback to manual check if utilities not loaded
    log_muted "Utilities not available, using manual cluster check..."

    NON_PRIMARY_COUNT=0
    PRIMARY_COUNT=0

    for POD in "${RUNNING_PODS[@]}"; do
      STATUS=$(oc exec "$POD" -n "$NAMESPACE" -- mysql -u"$DB_USER" -p"$DB_PASSWORD" -sN \
        -e "SELECT @@wsrep_cluster_status, @@wsrep_cluster_size, @@wsrep_local_state_comment, @@wsrep_ready;" 2>/dev/null || echo "UNREACHABLE")

      if [ "$STATUS" = "UNREACHABLE" ]; then
        log_warning "$POD: MySQL not responsive"
        continue
      fi

      read -r CLUSTER_STATUS CLUSTER_SIZE STATE READY <<< "$STATUS"

      if [ "$CLUSTER_STATUS" = "Primary" ]; then
        log_success "$POD: Status=$CLUSTER_STATUS, Size=$CLUSTER_SIZE, State=$STATE, Ready=$READY"
        ((PRIMARY_COUNT++))
      else
        log_critical "$POD: Status=$CLUSTER_STATUS, Size=$CLUSTER_SIZE, State=$STATE, Ready=$READY"
        ((NON_PRIMARY_COUNT++))
      fi
    done

    # Analysis
    section "CLUSTER ANALYSIS"

    TOTAL=$((PRIMARY_COUNT + NON_PRIMARY_COUNT))

    if [ $NON_PRIMARY_COUNT -eq $TOTAL ] && [ $TOTAL -gt 0 ]; then
      log_critical "✗ SPLIT-BRAIN DETECTED: All nodes in non-Primary state"
      log_warning "  → Quorum lost, manual bootstrap required"
      log_info "  → Run: oc exec -it deployment/pod-health-monitor -n $NAMESPACE -- /scripts/utils/galera-recover.sh"
    elif [ $PRIMARY_COUNT -gt 0 ] && [ $NON_PRIMARY_COUNT -gt 0 ]; then
      log_warning "⚠ PARTIAL CLUSTER: Some nodes non-Primary"
      log_warning "  → $PRIMARY_COUNT nodes Primary, $NON_PRIMARY_COUNT nodes non-Primary"
    elif [ $PRIMARY_COUNT -gt 0 ]; then
      log_success "✓ Cluster healthy: All running nodes in Primary state"
    fi
  fi
fi

# Step 4: Check grastate
section "GRASTATE ANALYSIS"

for POD in "${RUNNING_PODS[@]}"; do
  GRASTATE=$(oc exec "$POD" -n "$NAMESPACE" -- cat /bitnami/mariadb/data/grastate.dat 2>/dev/null || echo "UNAVAILABLE")

  if [ "$GRASTATE" = "UNAVAILABLE" ]; then
    log_warning "$POD: grastate.dat unavailable"
    continue
  fi

  SEQNO=$(echo "$GRASTATE" | grep "^seqno:" | awk '{print $2}')
  SAFE=$(echo "$GRASTATE" | grep "^safe_to_bootstrap:" | awk '{print $2}')

  if [ "$SEQNO" = "-1" ]; then
    log_warning "$POD: seqno=$SEQNO (unclean shutdown), safe_to_bootstrap=$SAFE"
  else
    log_success "$POD: seqno=$SEQNO, safe_to_bootstrap=$SAFE"
  fi
done

# Step 4: Recommendations
section "RECOMMENDATIONS"

if [ ${#CRASHED_PODS[@]} -gt 0 ]; then
  log_info "1. Fix crashed pods:"
  log_muted "   oc delete pod ${CRASHED_PODS[*]} -n $NAMESPACE"
  echo ""
fi

if [[ "${NON_PRIMARY_COUNT:-0}" -gt 0 ]]; then
  log_info "2. Recover from split-brain:"
  log_muted "   oc exec -it deployment/pod-health-monitor -n $NAMESPACE -- /scripts/utils/galera-recover.sh"
  echo ""
fi

if [[ "${CONFIG_STATUS:-}" == "CRITICAL" ]]; then
  log_info "3. Deploy recommended timeout configuration:"
  echo ""
  log_info "   WINDOWS (PowerShell script - RECOMMENDED):"
  echo "   .\scripts\deploy-galera-timeouts.ps1 -Namespace $NAMESPACE"
  echo ""
  log_muted "   Available profiles:"
  log_muted "   -Profile Full     # All recommended settings (default)"
  log_muted "   -Profile Minimal  # Only evs.inactive_timeout=PT30S"
  log_muted "   -Profile Dev      # Relaxed for 2-replica dev (PT20S/PT8S)"
  log_muted "   -Profile Test     # Moderate for 3-replica test (PT25S/PT10S)"
  log_muted "   -Profile Prod     # Aggressive for 5-replica prod (PT30S/PT10S)"
  echo ""
  log_info "   LINUX/MAC (Manual Helm commands):"
  log_muted "   helm repo add bitnami https://charts.bitnami.com/bitnami"
  log_muted "   helm repo update"
  echo "   helm upgrade mariadb-galera bitnami/mariadb-galera -n $NAMESPACE --reuse-values --set extraFlags=\"--wsrep-provider-options='evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT1S;evs.keepalive_period=PT2S;evs.join_retrans_period=PT2S;gcs.fc_limit=256;gcs.fc_factor=0.5'\""
  echo ""
  log_muted "   See config/mariadb/galera-timeouts.yaml for detailed documentation"
  echo ""
  log_info "   After deployment, verify with:"
  log_muted "   oc exec mariadb-galera-0 -n $NAMESPACE -- \\"
  log_muted "     mysql -u\$DB_USER -p\"\$DB_PASSWORD\" -sN \\"
  log_muted "     -e \"SHOW VARIABLES LIKE 'wsrep_provider_options';\" | grep inactive_timeout"
fi

echo ""
