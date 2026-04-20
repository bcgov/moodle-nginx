#!/bin/bash
# =============================================================================
# GALERA CLUSTER ADDRESS FIX
# =============================================================================
# Detects and fixes MARIADB_GALERA_CLUSTER_ADDRESS misconfiguration that causes
# nodes 1-4 to bootstrap independently instead of joining node 0.
#
# Root cause: database.sh Step 7 removed the cluster address (using "-" suffix)
# instead of setting it to proper discovery address.
#
# This script can be:
#   1. Called manually via PowerShell wrapper for diagnostics
#   2. Integrated into auto-heal workflow for automatic recovery
#
# Usage:
#   ./galera-fix-cluster-address.sh <namespace> <statefulset-name> [--fix]
#
# Returns:
#   0 = no issues detected, configuration is correct
#   1 = issues detected, corrective action taken (if --fix)
#   2 = issues detected, no action taken (diagnostic mode)
# =============================================================================

set -euo pipefail

# Arguments
NAMESPACE="${1:-}"
STS_NAME="${2:-mariadb-galera}"
FIX_MODE=false

if [[ "$#" -ge 3 && "$3" == "--fix" ]]; then
  FIX_MODE=true
fi

if [[ -z "$NAMESPACE" ]]; then
  echo "Usage: $0 <namespace> <statefulset-name> [--fix]"
  exit 1
fi

# =============================================================================
# IN-CLUSTER AUTHENTICATION
# =============================================================================

# Set writable kubeconfig path — container filesystem root is read-only
export KUBECONFIG="/tmp/.kube/config"
mkdir -p "$(dirname "$KUBECONFIG")"

# Authenticate with cluster (prefer OPENSHIFT_TOKEN over mounted SA token)
if [[ -n "${OPENSHIFT_TOKEN:-}" && -n "${OPENSHIFT_SERVER:-}" ]]; then
  # Primary: use OPENSHIFT_TOKEN environment variable (has proper permissions)
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:"

  # Try to switch to target namespace (optional - all commands use -n flag anyway)
  oc project "$NAMESPACE" 2>/dev/null || true
elif [[ -f "/var/run/secrets/kubernetes.io/serviceaccount/token" ]]; then
  # Fallback: use mounted service account token (may have limited permissions)
  SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CLUSTER_SERVER="${OPENSHIFT_SERVER:-https://kubernetes.default.svc}"

  # Login using service account token (suppress warnings, but show login result)
  oc login --token="$SA_TOKEN" --server="$CLUSTER_SERVER" --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:"

  # Try to switch to target namespace (optional - all commands use -n flag anyway)
  oc project "$NAMESPACE" 2>/dev/null || true
fi

# =============================================================================
# DIAGNOSTIC LOGIC
# =============================================================================

echo "======================================================================="
echo "  GALERA CLUSTER ADDRESS DIAGNOSTIC"
echo "======================================================================="
echo ""
echo "  Namespace: $NAMESPACE"
echo "  StatefulSet: $STS_NAME"
echo "  Mode: $([ "$FIX_MODE" = true ] && echo "FIX" || echo "DIAGNOSTIC")"
echo ""

# Check if StatefulSet exists
if ! oc get statefulset "$STS_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "ERROR: StatefulSet '$STS_NAME' not found in namespace '$NAMESPACE'"
  exit 1
fi

# Get target replicas (allow explicit override from orchestrator during staged 0->1 recovery)
TARGET_REPLICAS="${GALERA_TARGET_REPLICAS:-}"
if [[ -z "$TARGET_REPLICAS" ]]; then
  TARGET_REPLICAS=$(oc get statefulset "$STS_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
fi

if ! [[ "$TARGET_REPLICAS" =~ ^[0-9]+$ ]]; then
  TARGET_REPLICAS=0
fi

echo "  Target replicas: $TARGET_REPLICAS"
echo ""

# Extract Galera-related environment variables
CLUSTER_ADDR=$(oc get statefulset "$STS_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="mariadb-galera")].env[?(@.name=="MARIADB_GALERA_CLUSTER_ADDRESS")].value}' \
  2>/dev/null || echo "")

CLUSTER_BOOTSTRAP=$(oc get statefulset "$STS_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="mariadb-galera")].env[?(@.name=="MARIADB_GALERA_CLUSTER_BOOTSTRAP")].value}' \
  2>/dev/null || echo "")

FORCE_SAFE=$(oc get statefulset "$STS_NAME" -n "$NAMESPACE" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="mariadb-galera")].env[?(@.name=="MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP")].value}' \
  2>/dev/null || echo "")

# Generate proper cluster address
PROPER_ADDRESS="gcomm://"
for i in $(seq 0 $((TARGET_REPLICAS - 1))); do
  if [[ $i -gt 0 ]]; then
    PROPER_ADDRESS="${PROPER_ADDRESS},"
  fi
  PROPER_ADDRESS="${PROPER_ADDRESS}${STS_NAME}-${i}.${STS_NAME}-headless"
done

# Track issues found
ISSUES_FOUND=0
FIXES_REQUIRED=()

echo "======================================================================="
echo "  CONFIGURATION ANALYSIS"
echo "======================================================================="
echo ""

# Check MARIADB_GALERA_CLUSTER_ADDRESS
echo "CHECK 1: MARIADB_GALERA_CLUSTER_ADDRESS"
if [[ -z "$CLUSTER_ADDR" ]]; then
  echo "  ❌ NOT SET"
  echo "  Impact: Pods cannot discover each other, will bootstrap independently"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
  FIXES_REQUIRED+=("SET_CLUSTER_ADDRESS")
elif [[ "$CLUSTER_ADDR" == "gcomm://" ]]; then
  echo "  ⚠️  BOOTSTRAP MODE: $CLUSTER_ADDR"
  echo "  Impact: Only pod-0 will work, new pods will bootstrap independently"
  echo "  This setting is only correct during initial bootstrap or recovery"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
  FIXES_REQUIRED+=("UPDATE_CLUSTER_ADDRESS")
else
  echo "  ✅ SET: $CLUSTER_ADDR"

  # Verify it includes all expected nodes
  MISSING_NODES=()
  for i in $(seq 0 $((TARGET_REPLICAS - 1))); do
    if ! echo "$CLUSTER_ADDR" | grep -q "${STS_NAME}-${i}"; then
      MISSING_NODES+=("${STS_NAME}-${i}")
    fi
  done

  if [[ ${#MISSING_NODES[@]} -gt 0 ]]; then
    echo "  ⚠️  Missing nodes in address: ${MISSING_NODES[*]}"
    ISSUES_FOUND=$((ISSUES_FOUND + 1))
    FIXES_REQUIRED+=("UPDATE_CLUSTER_ADDRESS")
  fi
fi
echo ""

# Check MARIADB_GALERA_CLUSTER_BOOTSTRAP
echo "CHECK 2: MARIADB_GALERA_CLUSTER_BOOTSTRAP"
if [[ -z "$CLUSTER_BOOTSTRAP" ]]; then
  echo "  ℹ️  NOT SET (using default: no)"
elif [[ "$CLUSTER_BOOTSTRAP" == "yes" ]]; then
  echo "  ⚠️  ENABLED: $CLUSTER_BOOTSTRAP"
  echo "  Impact: All pods will try to bootstrap instead of joining cluster"
  echo "  This should only be 'yes' during recovery operations"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
  FIXES_REQUIRED+=("FIX_BOOTSTRAP")
else
  echo "  ✅ CORRECT: $CLUSTER_BOOTSTRAP"
fi
echo ""

# Check MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP
echo "CHECK 3: MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP"
if [[ -z "$FORCE_SAFE" ]]; then
  echo "  ℹ️  NOT SET (using default: no)"
elif [[ "$FORCE_SAFE" == "yes" ]]; then
  echo "  ⚠️  ENABLED: $FORCE_SAFE"
  echo "  Impact: May ignore safe_to_bootstrap checks, risking data loss"
  echo "  This should only be 'yes' during recovery operations"
  ISSUES_FOUND=$((ISSUES_FOUND + 1))
  FIXES_REQUIRED+=("FIX_FORCE_SAFE")
else
  echo "  ✅ CORRECT: $FORCE_SAFE"
fi
echo ""

# Summary
echo "======================================================================="
echo "  SUMMARY"
echo "======================================================================="
echo ""

if [[ $ISSUES_FOUND -eq 0 ]]; then
  echo "✅ No issues detected - cluster configuration looks healthy"
  echo ""
  exit 0
fi

echo "❌ Found $ISSUES_FOUND issue(s)"
echo ""

# Apply fixes if requested
if [[ "$FIX_MODE" = true ]]; then
  echo "======================================================================="
  echo "  APPLYING FIXES"
  echo "======================================================================="
  echo ""

  FIX_COUNT=0

  # Fix cluster address
  if [[ " ${FIXES_REQUIRED[*]} " =~ (SET_CLUSTER_ADDRESS|UPDATE_CLUSTER_ADDRESS) ]]; then
    FIX_COUNT=$((FIX_COUNT + 1))
    echo "[$FIX_COUNT] Setting MARIADB_GALERA_CLUSTER_ADDRESS..."
    echo "  Value: $PROPER_ADDRESS"

    if oc set env statefulset/"$STS_NAME" \
      "MARIADB_GALERA_CLUSTER_ADDRESS=${PROPER_ADDRESS}" \
      -n "$NAMESPACE" &>/dev/null; then
      echo "  ✅ Applied successfully"
    else
      echo "  ❌ Failed to apply"
    fi
    echo ""
  fi

  # Fix bootstrap flag
  if [[ " ${FIXES_REQUIRED[*]} " =~ FIX_BOOTSTRAP ]]; then
    FIX_COUNT=$((FIX_COUNT + 1))
    echo "[$FIX_COUNT] Setting MARIADB_GALERA_CLUSTER_BOOTSTRAP=no..."

    if oc set env statefulset/"$STS_NAME" \
      "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
      -n "$NAMESPACE" &>/dev/null; then
      echo "  ✅ Applied successfully"
    else
      echo "  ❌ Failed to apply"
    fi
    echo ""
  fi

  # Fix force safe flag
  if [[ " ${FIXES_REQUIRED[*]} " =~ FIX_FORCE_SAFE ]]; then
    FIX_COUNT=$((FIX_COUNT + 1))
    echo "[$FIX_COUNT] Setting MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no..."

    if oc set env statefulset/"$STS_NAME" \
      "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
      -n "$NAMESPACE" &>/dev/null; then
      echo "  ✅ Applied successfully"
    else
      echo "  ❌ Failed to apply"
    fi
    echo ""
  fi

  echo "======================================================================="
  echo "  FIXES APPLIED"
  echo "======================================================================="
  echo ""
  echo "Next steps:"
  echo "  1. Wait for StatefulSet update to propagate"
  echo "  2. If cluster is unhealthy, run bootstrap recovery"
  echo ""

  exit 1  # Return 1 to indicate fixes were applied
else
  echo "Recommended fixes:"
  echo ""

  if [[ " ${FIXES_REQUIRED[*]} " =~ (SET_CLUSTER_ADDRESS|UPDATE_CLUSTER_ADDRESS) ]]; then
    echo "  • Set MARIADB_GALERA_CLUSTER_ADDRESS=$PROPER_ADDRESS"
  fi

  if [[ " ${FIXES_REQUIRED[*]} " =~ FIX_BOOTSTRAP ]]; then
    echo "  • Set MARIADB_GALERA_CLUSTER_BOOTSTRAP=no"
  fi

  if [[ " ${FIXES_REQUIRED[*]} " =~ FIX_FORCE_SAFE ]]; then
    echo "  • Set MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no"
  fi

  echo ""
  echo "Run with --fix flag to apply these fixes automatically"
  echo ""

  exit 2  # Return 2 to indicate diagnostic mode found issues
fi
