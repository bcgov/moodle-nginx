#!/bin/bash
# =============================================================================
# SHARED GALERA UTILITY FUNCTIONS
# =============================================================================
# Common functions used across multiple Galera management scripts
# Source this file in other scripts: source "$(dirname "$0")/_galera_utils.sh"
# =============================================================================

# Ensure this file is sourced only once
if [[ -n "${_GALERA_UTILS_LOADED:-}" ]]; then
  return 0
fi
_GALERA_UTILS_LOADED=1

# =============================================================================
# AUTHENTICATION & CLUSTER ACCESS
# =============================================================================

# Setup OpenShift authentication for in-cluster execution
# Sets up writable KUBECONFIG and logs in using available credentials
galera_setup_auth() {
  local target_namespace="${DEPLOY_NAMESPACE:-${NAMESPACE:-}}"

  # Set writable kubeconfig path (container filesystem root is read-only)
  export KUBECONFIG="${KUBECONFIG:-/tmp/.kube/config}"
  mkdir -p "$(dirname "$KUBECONFIG")" 2>/dev/null || true

  # Suppress oc CLI warnings (legacy token, insecure TLS)
  export KUBECTL_WARN_EXTERNAL_UNKNOWN=false

  # Authenticate with cluster (prefer OPENSHIFT_TOKEN over mounted SA token)
  if [[ -n "${OPENSHIFT_TOKEN:-}" && -n "${OPENSHIFT_SERVER:-}" ]]; then
    # Primary: use OPENSHIFT_TOKEN environment variable (has proper permissions)
    oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" \
      --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:" || true

    # Try to switch to target namespace (optional - commands use -n flag)
    [[ -n "$target_namespace" ]] && oc project "$target_namespace" 2>/dev/null || true
  elif [[ -f "/var/run/secrets/kubernetes.io/serviceaccount/token" ]]; then
    # Fallback: use mounted service account token
    SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
    CLUSTER_SERVER="${OPENSHIFT_SERVER:-https://kubernetes.default.svc}"

    oc login --token="$SA_TOKEN" --server="$CLUSTER_SERVER" \
      --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:" || true

    [[ -n "$target_namespace" ]] && oc project "$target_namespace" 2>/dev/null || true
  fi

  if ! oc whoami >/dev/null 2>&1; then
    echo "[ERROR] OpenShift authentication is not initialized" >&2
    return 1
  fi

  if [[ -n "$target_namespace" ]] && ! oc get namespace "$target_namespace" -o name >/dev/null 2>&1; then
    echo "[ERROR] OpenShift access to namespace '$target_namespace' is not available" >&2
    return 1
  fi

  return 0
}

# Get database root password from secret
# Args: namespace
# Returns: password string (via stdout)
galera_get_root_password() {
  local namespace="$1"
  local password_b64

  password_b64=$(oc get secret mariadb-galera -n "$namespace" \
    -o jsonpath='{.data.mariadb-root-password}' 2>/dev/null || echo "")

  if [[ -z "$password_b64" ]]; then
    echo "ERROR: Could not retrieve mariadb-root-password from secret" >&2
    return 1
  fi

  echo "$password_b64" | base64 -d
}

# =============================================================================
# CLUSTER HEALTH & STATUS
# =============================================================================

# Check if a pod is running and ready
# Args: pod_name namespace
# Returns: 0 if running, 1 otherwise
galera_pod_is_running() {
  local pod_name="$1"
  local namespace="$2"
  local phase

  phase=$(oc get pod "$pod_name" -n "$namespace" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  [[ "$phase" == "Running" ]]
}

# Wait for pod to be running
# Args: pod_name namespace timeout_seconds
# Returns: 0 if running within timeout, 1 otherwise
galera_wait_for_pod() {
  local pod_name="$1"
  local namespace="$2"
  local timeout="${3:-300}"
  local elapsed=0

  while [[ $elapsed -lt $timeout ]]; do
    if galera_pod_is_running "$pod_name" "$namespace"; then
      return 0
    fi
    sleep 5
    elapsed=$((elapsed + 5))
  done

  return 1
}

# Check Galera cluster health for a specific pod
# Args: pod_name namespace root_password
# Returns: JSON-like output with status variables
galera_check_pod_health() {
  local pod_name="$1"
  local namespace="$2"
  local root_password="$3"

  local status
  status=$(oc exec "$pod_name" -n "$namespace" -- \
    mysql -uroot -p"$root_password" -sN \
    -e "SELECT CONCAT(
      @@wsrep_cluster_status, '|',
      @@wsrep_cluster_size, '|',
      @@wsrep_local_state_comment, '|',
      @@wsrep_ready, '|',
      @@wsrep_cluster_state_uuid
    );" 2>/dev/null || echo "UNREACHABLE||||")

  IFS='|' read -r cluster_status cluster_size local_state ready uuid <<< "$status"

  # Output in parseable format
  echo "CLUSTER_STATUS=$cluster_status"
  echo "CLUSTER_SIZE=$cluster_size"
  echo "LOCAL_STATE=$local_state"
  echo "READY=$ready"
  echo "UUID=$uuid"

  # Return success if healthy
  [[ "$cluster_status" == "Primary" && "$ready" == "ON" ]]
}

# =============================================================================
# GRASTATE.DAT PARSING
# =============================================================================

# Parse grastate.dat content
# Args: grastate_content (via stdin or arg)
# Returns: Parseable key=value output
galera_parse_grastate() {
  local content="${1:-$(cat)}"
  local seqno uuid safe_to_bootstrap

  seqno=$(echo "$content" | grep "^seqno:" | awk '{print $2}')
  uuid=$(echo "$content" | grep "^uuid:" | awk '{print $2}')
  safe_to_bootstrap=$(echo "$content" | grep "^safe_to_bootstrap:" | awk '{print $2}')

  echo "SEQNO=${seqno:--1}"
  echo "UUID=${uuid:-unknown}"
  echo "SAFE_TO_BOOTSTRAP=${safe_to_bootstrap:-0}"
}

# Read grastate.dat from a running pod
# Args: pod_name namespace
# Returns: Parseable grastate output via galera_parse_grastate
galera_read_grastate_from_pod() {
  local pod_name="$1"
  local namespace="$2"
  local content

  content=$(oc exec "$pod_name" -n "$namespace" -- \
    cat /bitnami/mariadb/data/grastate.dat 2>/dev/null || echo "")

  if [[ -z "$content" ]]; then
    echo "ERROR=Could not read grastate.dat from pod $pod_name"
    return 1
  fi

  echo "POD=$pod_name"
  galera_parse_grastate "$content"
}

# Read grastate.dat from PVC using debug pod
# Args: pvc_name namespace
# Returns: Parseable grastate output via galera_parse_grastate
galera_read_grastate_from_pvc() {
  local pvc_name="$1"
  local namespace="$2"
  local debug_pod="grastate-reader-$$"
  local content

  # Create debug pod
  cat <<EOF | oc apply -f - >/dev/null 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: $debug_pod
  namespace: $namespace
spec:
  containers:
  - name: reader
    image: busybox
    command: ['cat', '/data/grastate.dat']
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $pvc_name
  restartPolicy: Never
EOF

  # Wait for completion
  local waited=0
  while [[ $waited -lt 60 ]]; do
    local phase
    phase=$(oc get pod "$debug_pod" -n "$namespace" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

    if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
      break
    fi
    sleep 2
    waited=$((waited + 2))
  done

  # Get content
  content=$(oc logs "$debug_pod" -n "$namespace" 2>/dev/null || echo "")

  # Cleanup
  oc delete pod "$debug_pod" -n "$namespace" --ignore-not-found=true >/dev/null 2>&1

  if [[ -z "$content" ]]; then
    echo "ERROR=Could not read grastate.dat from PVC $pvc_name"
    return 1
  fi

  echo "PVC=$pvc_name"
  galera_parse_grastate "$content"
}

# =============================================================================
# REPLICA COUNT DETECTION
# =============================================================================

# Get target replica count from annotation, CSV, or StatefulSet
# Args: namespace statefulset_name
# Returns: replica count
galera_get_target_replicas() {
  local namespace="$1"
  local sts_name="$2"
  local annotated csv_replicas current

  # Try annotation first
  annotated=$(oc get statefulset "$sts_name" -n "$namespace" \
    -o jsonpath='{.metadata.annotations.last-known-replicas}' 2>/dev/null || echo "")

  if [[ "$annotated" =~ ^[0-9]+$ ]]; then
    echo "$annotated"
    return 0
  fi

  # Try CSV
  local csv_file="./openshift/${namespace}-sizing.csv"
  if [[ -f "$csv_file" ]]; then
    csv_replicas=$(grep "^mariadb-galera," "$csv_file" 2>/dev/null | cut -d',' -f3 || echo "")
    if [[ "$csv_replicas" =~ ^[0-9]+$ ]]; then
      echo "$csv_replicas"
      return 0
    fi
  fi

  # Fallback to current
  current=$(oc get statefulset "$sts_name" -n "$namespace" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "5")

  echo "$current"
}

# =============================================================================
# LOGGING & OUTPUT
# =============================================================================

# Color codes (only if terminal supports it)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  GRAY='\033[0;90m'
  NC='\033[0m'
else
  RED=''
  YELLOW=''
  GREEN=''
  CYAN=''
  GRAY=''
  NC=''
fi

log_critical() { echo -e "${RED}$1${NC}" >&2; }
log_warning() { echo -e "${YELLOW}$1${NC}" >&2; }
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
# UTILITY FUNCTIONS
# =============================================================================

# Check if running in non-interactive mode
is_non_interactive() {
  [[ "${NON_INTERACTIVE:-false}" == "true" ]] || [[ ! -t 0 ]]
}

# Prompt user for confirmation (skips in non-interactive mode)
# Args: prompt_message required_response
# Returns: 0 if confirmed, 1 otherwise
prompt_confirm() {
  local message="$1"
  local required="${2:-yes}"

  if is_non_interactive; then
    log_warning "Non-interactive mode: skipping confirmation"
    return 0
  fi

  echo -e "${YELLOW}${message}${NC}"
  read -r response

  if [[ "$response" == "$required" ]]; then
    return 0
  else
    log_warning "Confirmation declined"
    return 1
  fi
}

# Export functions for use in subshells
export -f galera_setup_auth
export -f galera_get_root_password
export -f galera_pod_is_running
export -f galera_wait_for_pod
export -f galera_check_pod_health
export -f galera_parse_grastate
export -f galera_read_grastate_from_pod
export -f galera_read_grastate_from_pvc
export -f galera_get_target_replicas
export -f log_critical log_warning log_success log_info log_muted section
export -f is_non_interactive prompt_confirm
