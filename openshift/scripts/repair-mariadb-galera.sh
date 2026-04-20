#!/bin/bash
# =============================================================================
# REPAIR MARIADB GALERA (NAMESPACE-LOCKED SHORTCUT)
# =============================================================================
# Purpose:
#   Run Galera safe recovery with zero cross-namespace ambiguity.
#
# Safety model:
#   - Namespace is auto-detected from in-cluster service account file.
#   - Optional DEPLOY_NAMESPACE/NAMESPACE env vars must match detected namespace.
#   - Target replicas are read from right-sizing CSV via get_sizing_replicas().
#   - Cross-namespace execution is blocked.
#
# Usage (in pod-health-monitor):
#   source /scripts/repair-mariadb-galera.sh
#
# Step control (run individual recovery phases for debugging):
#   GALERA_FROM_STEP=7 source /scripts/repair-mariadb-galera.sh   # start at step 7
#   GALERA_STEP=7 source /scripts/repair-mariadb-galera.sh        # run only step 7
#   GALERA_FROM_STEP=7 GALERA_TO_STEP=9 source /scripts/repair-mariadb-galera.sh
#
# Steps:
#   1 = Pre-flight check + save annotation
#   2 = Scale to 0 + clear bad env vars
#   3 = Delete secondary PVCs + fix grastate.dat
#   4 = Enable bootstrap env vars
#   5 = Scale to 1 + wait for galera-0 Ready
#   7 = Set partition=1, disable bootstrap, verify Primary
#   8 = Scale to target + NON-PRIMARY deadlock detection
#   9 = Wait for sync + remove partition + final health check
#
# Optional overrides:
#   STS_NAME=mariadb-galera source /scripts/repair-mariadb-galera.sh
#   GALERA_TARGET_REPLICAS=5 source /scripts/repair-mariadb-galera.sh
#
# Related docs:
#   - ../../docs/manual-galera-troubleshooting.md
#   - ./README.md
# =============================================================================

set -euo pipefail

# Load utility modules
if [[ -f "/scripts/_utils.sh" ]]; then
  source /scripts/_utils.sh
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" ]]; then
  source "$(dirname "${BASH_SOURCE[0]}")/_utils.sh"
else
  echo "[ERROR] _utils.sh not found; cannot continue"
  return 1 2>/dev/null || exit 1
fi

STS_NAME="${STS_NAME:-mariadb-galera}"

# Detect namespace from mounted service account context (authoritative in-cluster source).
DETECTED_NAMESPACE="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)"
if [[ -z "$DETECTED_NAMESPACE" ]]; then
  echo "[ERROR] Could not detect in-cluster namespace from service account"
  return 1 2>/dev/null || exit 1
fi

# If callers provided namespace env vars, enforce exact match.
if [[ -n "${DEPLOY_NAMESPACE:-}" && "$DEPLOY_NAMESPACE" != "$DETECTED_NAMESPACE" ]]; then
  echo "[ERROR] Namespace mismatch: DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE, detected=$DETECTED_NAMESPACE"
  echo "[ERROR] Cross-namespace recovery is blocked by design"
  return 1 2>/dev/null || exit 1
fi
if [[ -n "${NAMESPACE:-}" && "$NAMESPACE" != "$DETECTED_NAMESPACE" ]]; then
  echo "[ERROR] Namespace mismatch: NAMESPACE=$NAMESPACE, detected=$DETECTED_NAMESPACE"
  echo "[ERROR] Cross-namespace recovery is blocked by design"
  return 1 2>/dev/null || exit 1
fi

# Lock both env vars to detected namespace for downstream utilities.
export DEPLOY_NAMESPACE="$DETECTED_NAMESPACE"
export NAMESPACE="$DETECTED_NAMESPACE"

# Resolve target replicas (priority: env override > CSV > StatefulSet spec > default 3).
TARGET_REPLICAS="${GALERA_TARGET_REPLICAS:-}"
REPLICAS_SOURCE="env override"

if [[ -z "$TARGET_REPLICAS" ]]; then
  TARGET_REPLICAS="$(get_sizing_replicas "$STS_NAME" "$DETECTED_NAMESPACE" 2>/dev/null || true)"
  REPLICAS_SOURCE="sizing CSV"
fi

# Fallback: read current StatefulSet spec.replicas
if [[ -z "$TARGET_REPLICAS" || ! "$TARGET_REPLICAS" =~ ^[0-9]+$ || "$TARGET_REPLICAS" -lt 1 ]]; then
  echo "[WARN] Sizing CSV not available; falling back to StatefulSet spec.replicas"
  TARGET_REPLICAS="$(oc get statefulset "$STS_NAME" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)"
  REPLICAS_SOURCE="StatefulSet spec"
fi

# Last resort default
if [[ -z "$TARGET_REPLICAS" || ! "$TARGET_REPLICAS" =~ ^[0-9]+$ || "$TARGET_REPLICAS" -lt 1 ]]; then
  echo "[WARN] Could not read StatefulSet spec; defaulting to 3 replicas"
  TARGET_REPLICAS=3
  REPLICAS_SOURCE="default"
fi

echo ""
echo "======================================================================="
echo "MARIADB GALERA REPAIR SHORTCUT"
echo "======================================================================="
echo "Namespace: $DETECTED_NAMESPACE"
echo "StatefulSet: $STS_NAME"
echo "Target replicas ($REPLICAS_SOURCE): $TARGET_REPLICAS"
echo ""

# Enable MANUAL_MODE to prevent the monitor from interfering with recovery.
# The monitor checks this env var every cycle and skips all auto-healing when true.
MANUAL_MODE_WAS=$(oc set env deployment/pod-health-monitor --list -n "$DETECTED_NAMESPACE" 2>/dev/null \
  | grep '^MANUAL_MODE=' | cut -d= -f2 || echo "")

if [[ "${MANUAL_MODE_WAS,,}" != "true" ]]; then
  echo "[SAFE] Enabling MANUAL_MODE on pod-health-monitor to prevent auto-heal conflicts..."
  oc set env deployment/pod-health-monitor MANUAL_MODE=true -n "$DETECTED_NAMESPACE" 2>/dev/null || true
  echo "[OK] MANUAL_MODE=true (auto-healing disabled during recovery)"
else
  echo "[INFO] MANUAL_MODE already enabled — skipping"
fi
echo ""

# Restore MANUAL_MODE after recovery (success or failure).
_repair_cleanup() {
  local exit_code=$?
  if [[ "${MANUAL_MODE_WAS,,}" != "true" ]]; then
    echo ""
    echo "[SAFE] Restoring MANUAL_MODE=false on pod-health-monitor..."
    oc set env deployment/pod-health-monitor MANUAL_MODE=false -n "$DETECTED_NAMESPACE" 2>/dev/null || true
    echo "[OK] Auto-healing re-enabled"
  fi
  return $exit_code
}
trap _repair_cleanup EXIT

# Execute safe upgrade flow.
# GALERA_STEP is a convenience shortcut: sets both FROM and TO to the same value.
if [[ -n "${GALERA_STEP:-}" ]]; then
  export GALERA_FROM_STEP="$GALERA_STEP"
  export GALERA_TO_STEP="$GALERA_STEP"
fi

if [[ -n "${GALERA_FROM_STEP:-}" || -n "${GALERA_TO_STEP:-}" ]]; then
  echo "Step control: FROM=${GALERA_FROM_STEP:-1} TO=${GALERA_TO_STEP:-99}"
  echo ""
fi

galera_safe_upgrade "$STS_NAME" "$TARGET_REPLICAS" "$DETECTED_NAMESPACE"
