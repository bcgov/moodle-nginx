#!/bin/bash
# =============================================================================
# GALERA CLUSTER BOOTSTRAP RECOVERY
# =============================================================================
# Comprehensive bootstrap recovery for Galera cluster after split-brain or
# total failure. Analyzes grastate.dat, selects best node, and performs
# safe recovery with gradual scale-up and validation.
#
# Usage (Interactive - default):
#   oc exec deployment/pod-health-monitor -n <namespace> -- \
#     /scripts/utils/galera-bootstrap.sh --namespace=<ns>
#
# Usage (Non-Interactive - for automation):
#   /scripts/utils/galera-bootstrap.sh \
#     --non-interactive \
#     --namespace=<ns> \
#     --target-replicas=5 \
#     --force
#
# Flags:
#   --non-interactive       Skip prompts, require all arguments
#   --namespace=<ns>        Target namespace (required)
#   --statefulset=<name>    StatefulSet name (default: mariadb-galera)
#   --target-replicas=<n>   Target replica count (auto-detected if omitted)
#   --bootstrap-node=<pod>  Override bootstrap node selection
#   --force                 Skip confirmation prompts
#   --analyze-only          Only analyze grastate, don't bootstrap
#
# Returns:
#   0 = success
#   1 = failure
#   2 = analysis complete (--analyze-only)
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
TARGET_REPLICAS=""
BOOTSTRAP_NODE=""
FORCE=false
ANALYZE_ONLY=false
NON_INTERACTIVE=false

print_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Comprehensive Galera cluster bootstrap recovery with analysis and validation.

OPTIONS:
  --non-interactive          Skip prompts, require all arguments
  --namespace=<ns>           Target namespace (REQUIRED)
  --statefulset=<name>       StatefulSet name (default: mariadb-galera)
  --target-replicas=<n>      Target replica count (auto-detected if omitted)
  --bootstrap-node=<pod>     Override bootstrap node selection
  --force                    Skip confirmation prompts
  --analyze-only             Only analyze grastate, don't bootstrap
  -h, --help                 Show this help message

EXAMPLES:
  # Interactive mode (prompts for confirmation)
  $0 --namespace=950003-prod

  # Non-interactive mode (for automation/PowerShell)
  $0 --non-interactive --namespace=950003-prod --target-replicas=5 --force

  # Analysis only (no changes)
  $0 --namespace=950003-prod --analyze-only

EXIT CODES:
  0 = Success
  1 = Failure
  2 = Analysis complete (--analyze-only)
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
    --target-replicas=*)
      TARGET_REPLICAS="${1#*=}"
      shift
      ;;
    --bootstrap-node=*)
      BOOTSTRAP_NODE="${1#*=}"
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --analyze-only)
      ANALYZE_ONLY=true
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

# In non-interactive mode, require target-replicas if not analyze-only
if [[ "$NON_INTERACTIVE" == "true" ]] && [[ "$ANALYZE_ONLY" == "false" ]] && [[ -z "$TARGET_REPLICAS" ]]; then
  log_critical "ERROR: --target-replicas required in non-interactive mode"
  echo ""
  print_usage
  exit 1
fi

# =============================================================================
# INTERNAL FUNCTIONS
# =============================================================================

# Analyze grastate.dat from all nodes
# Sets global variables: GRASTATE_DATA (array), BEST_NODE, MAX_SEQNO
analyze_grastate() {
  section "GRASTATE ANALYSIS"

  log_info "Reading grastate.dat from all nodes..."

  # Get running pods
  local running_pods
  running_pods=$(oc get pods -l "app.kubernetes.io/name=$STATEFULSET" \
    -n "$NAMESPACE" --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

  declare -g -A GRASTATE_DATA
  MAX_SEQNO=-99999999
  BEST_NODE=""

  if [[ -n "$running_pods" ]]; then
    log_muted "  Reading from running pods..."
    for pod in $running_pods; do
      local result
      result=$(galera_read_grastate_from_pod "$pod" "$NAMESPACE" 2>/dev/null || echo "ERROR=failed")

      # Parse result
      local pod_name seqno uuid safe
      eval "$result"  # Sets POD, SEQNO, UUID, SAFE_TO_BOOTSTRAP, ERROR

      if [[ -n "${ERROR:-}" ]]; then
        log_warning "    $pod: $ERROR"
        continue
      fi

      GRASTATE_DATA["$POD"]="$SEQNO|$UUID|$SAFE_TO_BOOTSTRAP"

      log_success "    $POD: seqno=$SEQNO, uuid=$UUID, safe=$SAFE_TO_BOOTSTRAP"

      # Track highest seqno (excluding -1)
      if [[ "$SEQNO" != "-1" ]] && [[ "$SEQNO" -gt "$MAX_SEQNO" ]]; then
        MAX_SEQNO=$SEQNO
        BEST_NODE=$POD
      fi
    done
  else
    log_muted "  No running pods, reading from PVCs..."

    # Find PVCs
    local pvcs
    pvcs=$(oc get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

    for pvc in $pvcs; do
      if [[ ! "$pvc" =~ ^data-$STATEFULSET-[0-9]+$ ]]; then
        continue
      fi

      local result
      result=$(galera_read_grastate_from_pvc "$pvc" "$NAMESPACE" 2>/dev/null || echo "ERROR=failed")

      # Parse result
      eval "$result"  # Sets PVC, SEQNO, UUID, SAFE_TO_BOOTSTRAP, ERROR

      if [[ -n "${ERROR:-}" ]]; then
        log_warning "    $pvc: $ERROR"
        continue
      fi

      # Extract pod name from PVC (data-mariadb-galera-0 -> mariadb-galera-0)
      local pod_name="${pvc#data-}"

      GRASTATE_DATA["$pod_name"]="$SEQNO|$UUID|$SAFE_TO_BOOTSTRAP"

      log_success "    $pod_name: seqno=$SEQNO, uuid=$UUID, safe=$SAFE_TO_BOOTSTRAP"

      if [[ "$SEQNO" != "-1" ]] && [[ "$SEQNO" -gt "$MAX_SEQNO" ]]; then
        MAX_SEQNO=$SEQNO
        BEST_NODE=$pod_name
      fi
    done
  fi

  # Handle edge cases
  if [[ ${#GRASTATE_DATA[@]} -eq 0 ]]; then
    log_critical "ERROR: Could not read grastate.dat from any node"
    return 1
  fi

  # Check for all seqno=-1 (unclean shutdown)
  local all_negative=true
  for pod in "${!GRASTATE_DATA[@]}"; do
    IFS='|' read -r seqno uuid safe <<< "${GRASTATE_DATA[$pod]}"
    if [[ "$seqno" != "-1" ]]; then
      all_negative=false
      break
    fi
  done

  if [[ "$all_negative" == "true" ]]; then
    log_warning "All nodes have seqno=-1 (unclean shutdown)"

    # Look for safe_to_bootstrap=1
    for pod in "${!GRASTATE_DATA[@]}"; do
      IFS='|' read -r seqno uuid safe <<< "${GRASTATE_DATA[$pod]}"
      if [[ "$safe" == "1" ]]; then
        BEST_NODE=$pod
        log_success "  Found safe_to_bootstrap=1: $BEST_NODE"
        return 0
      fi
    done

    # Default to pod-0
    BEST_NODE="$STATEFULSET-0"
    log_warning "  No safe_to_bootstrap flag, defaulting to: $BEST_NODE"
  else
    log_success "Best bootstrap node: $BEST_NODE (seqno: $MAX_SEQNO)"
  fi
}

# Scale StatefulSet to specific replica count
# Args: replica_count
scale_statefulset() {
  local replicas="$1"

  log_info "Scaling StatefulSet to $replicas replicas..."
  if ! oc scale statefulset "$STATEFULSET" --replicas="$replicas" -n "$NAMESPACE" >/dev/null 2>&1; then
    log_critical "ERROR: Failed to scale StatefulSet"
    return 1
  fi

  log_success "  Scaled to $replicas"
}

# Bootstrap initial pod (pod-0)
# Args: root_password
bootstrap_initial_pod() {
  local root_password="$1"

  section "BOOTSTRAPPING INITIAL NODE"

  log_info "Scaling to 1 replica (bootstrap mode)..."
  scale_statefulset 1 || return 1

  local bootstrap_pod="$STATEFULSET-0"

  log_info "Waiting for $bootstrap_pod to start..."
  if ! galera_wait_for_pod "$bootstrap_pod" "$NAMESPACE" 300; then
    log_critical "ERROR: $bootstrap_pod did not start"
    log_muted "  Check logs: oc logs $bootstrap_pod -n $NAMESPACE"
    return 1
  fi

  log_info "Waiting for MariaDB to be accessible..."
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    sleep 5
    if galera_check_pod_health "$bootstrap_pod" "$NAMESPACE" "$root_password" >/dev/null 2>&1; then
      log_success "Bootstrap successful - cluster is Primary"
      return 0
    fi
    attempts=$((attempts + 1))
  done

  log_critical "ERROR: MariaDB did not become accessible"
  log_muted "  Check logs: oc logs $bootstrap_pod -n $NAMESPACE"
  return 1
}

# Verify and fix cluster address configuration
verify_cluster_address() {
  section "VERIFYING CLUSTER CONFIGURATION"

  log_info "Running cluster address diagnostic..."

  # Try to find pod-health-monitor
  local monitor_pod
  monitor_pod=$(oc get pod -l app=pod-health-monitor -n "$NAMESPACE" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  if [[ -z "$monitor_pod" ]]; then
    log_warning "pod-health-monitor not found, skipping cluster address check"
    log_muted "  Manual verification: check MARIADB_GALERA_CLUSTER_ADDRESS env var"
    return 0
  fi

  # Call fix script
  local fix_script="/scripts/utils-galera-fix-cluster-address.sh"
  if ! oc exec "$monitor_pod" -n "$NAMESPACE" -- \
    bash -c "$fix_script $NAMESPACE $STATEFULSET --fix" >/dev/null 2>&1; then

    local exit_code=$?
    if [[ $exit_code -eq 1 ]]; then
      log_success "Cluster address configuration fixed"
    else
      log_warning "Cluster address check returned code: $exit_code"
      log_muted "  Continuing, but scale-up may fail..."
    fi
  else
    log_success "Cluster address configuration verified"
  fi
}

# Scale up gradually with validation
# Args: target_replicas root_password
scale_up_gradually() {
  local target="$1"
  local root_password="$2"

  section "GRADUAL SCALE-UP"

  for i in $(seq 2 "$target"); do
    log_info "[$i/$target] Scaling to $i replicas..."
    scale_statefulset "$i" || return 1

    local pod_name="$STATEFULSET-$((i - 1))"
    log_muted "  Waiting for $pod_name..."

    # Wait for pod creation
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
      if oc get pod "$pod_name" -n "$NAMESPACE" --ignore-not-found=true \
        -o jsonpath='{.metadata.name}' 2>/dev/null | grep -q "$pod_name"; then
        break
      fi
      sleep 2
      attempts=$((attempts + 1))
    done

    if [[ $attempts -ge 30 ]]; then
      log_critical "ERROR: $pod_name was not created"
      return 1
    fi

    # Wait for pod running
    if ! galera_wait_for_pod "$pod_name" "$NAMESPACE" 300; then
      log_critical "ERROR: $pod_name did not start"
      return 1
    fi

    # Wait for sync
    log_muted "  Waiting for $pod_name to sync..."
    attempts=0
    while [[ $attempts -lt 30 ]]; do
      sleep 5
      local health
      health=$(galera_check_pod_health "$pod_name" "$NAMESPACE" "$root_password" 2>/dev/null || echo "")

      if [[ -n "$health" ]]; then
        eval "$health"  # Sets CLUSTER_STATUS, CLUSTER_SIZE, LOCAL_STATE, etc.

        if [[ "$CLUSTER_STATUS" == "Primary" ]] && \
           [[ "$LOCAL_STATE" == "Synced" ]] && \
           [[ "$CLUSTER_SIZE" == "$i" ]]; then
          log_success "  $pod_name synced ($CLUSTER_SIZE/$target nodes)"
          break
        fi
      fi
      attempts=$((attempts + 1))
    done

    if [[ $attempts -ge 30 ]]; then
      log_critical "ERROR: $pod_name did not sync"
      log_muted "  State: $LOCAL_STATE, Size: $CLUSTER_SIZE"
      return 1
    fi
  done

  log_success "All $target replicas scaled and synced"
}

# Validate final cluster state
validate_final_state() {
  local target="$1"
  local root_password="$2"

  section "FINAL VALIDATION"

  log_info "Checking all nodes for consistency..."

  local uuids=()
  local all_primary=true

  for i in $(seq 0 $((target - 1))); do
    local pod_name="$STATEFULSET-$i"
    local health
    health=$(galera_check_pod_health "$pod_name" "$NAMESPACE" "$root_password" 2>/dev/null || echo "")

    if [[ -z "$health" ]]; then
      log_warning "  $pod_name: Not accessible"
      all_primary=false
      continue
    fi

    eval "$health"

    if [[ "$CLUSTER_STATUS" != "Primary" ]]; then
      log_warning "  $pod_name: Status=$CLUSTER_STATUS (expected Primary)"
      all_primary=false
    else
      log_success "  $pod_name: Primary, Size=$CLUSTER_SIZE, UUID=$UUID"
    fi

    uuids+=("$UUID")
  done

  # Check UUID consistency
  local unique_uuids
  unique_uuids=$(printf '%s\n' "${uuids[@]}" | sort -u | wc -l)

  if [[ $unique_uuids -gt 1 ]]; then
    log_critical "ERROR: Multiple cluster UUIDs detected (split-brain)"
    return 1
  fi

  if [[ "$all_primary" != "true" ]]; then
    log_warning "WARNING: Not all nodes are Primary"
    return 1
  fi

  log_success "Cluster validation passed: All nodes Primary with same UUID"
  return 0
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
  section "GALERA CLUSTER BOOTSTRAP RECOVERY"

  log_info "Namespace: $NAMESPACE"
  log_info "StatefulSet: $STATEFULSET"
  log_info "Mode: $(is_non_interactive && echo 'NON-INTERACTIVE' || echo 'INTERACTIVE')"
  echo ""

  # Setup authentication
  galera_setup_auth

  # Get root password
  log_info "Retrieving database credentials..."
  local root_password
  root_password=$(galera_get_root_password "$NAMESPACE") || exit 1
  log_success "  Credentials retrieved"
  echo ""

  # Determine target replicas
  if [[ -z "$TARGET_REPLICAS" ]]; then
    TARGET_REPLICAS=$(galera_get_target_replicas "$NAMESPACE" "$STATEFULSET")
    log_info "Auto-detected target replicas: $TARGET_REPLICAS"
  else
    log_info "Target replicas: $TARGET_REPLICAS (from argument)"
  fi
  echo ""

  # Analyze grastate
  analyze_grastate || exit 1
  echo ""

  # Override bootstrap node if specified
  if [[ -n "$BOOTSTRAP_NODE" ]]; then
    log_info "Bootstrap node override: $BOOTSTRAP_NODE"
    BEST_NODE=$BOOTSTRAP_NODE
  else
    log_info "Recommended bootstrap node: $BEST_NODE"
  fi
  echo ""

  # If analyze-only, exit here
  if [[ "$ANALYZE_ONLY" == "true" ]]; then
    section "ANALYSIS COMPLETE"
    log_info "Recommended action:"
    log_muted "  $0 --namespace=$NAMESPACE --target-replicas=$TARGET_REPLICAS"
    echo ""
    exit 2
  fi

  # Confirmation prompt (unless --force)
  if [[ "$FORCE" != "true" ]] && ! is_non_interactive; then
    section "BOOTSTRAP RECOVERY PLAN"
    echo "  Bootstrap node: $BEST_NODE"
    echo "  Target replicas: $TARGET_REPLICAS"
    echo ""
    echo "  This will:"
    echo "    1. Scale to 0 (clean shutdown)"
    echo "    2. Bootstrap from $BEST_NODE"
    echo "    3. Verify cluster address configuration"
    echo "    4. Scale gradually: 1→2→3→...→$TARGET_REPLICAS"
    echo "    5. Validate final state"
    echo ""

    if ! prompt_confirm "Type 'BOOTSTRAP' to confirm:" "BOOTSTRAP"; then
      log_info "Bootstrap cancelled"
      exit 0
    fi
    echo ""
  fi

  # Execute recovery
  section "STARTING BOOTSTRAP RECOVERY"

  # Step 1: Scale to 0
  log_info "[1/5] Scaling to 0..."
  scale_statefulset 0 || exit 1
  sleep 15
  log_success "  All pods terminated"
  echo ""

  # Step 2: Bootstrap initial pod
  log_info "[2/5] Bootstrapping initial node..."
  bootstrap_initial_pod "$root_password" || exit 1
  echo ""

  # Step 3: Verify cluster address
  log_info "[3/5] Verifying cluster configuration..."
  verify_cluster_address
  echo ""

  # Step 4: Scale up gradually
  log_info "[4/5] Scaling up gradually..."
  scale_up_gradually "$TARGET_REPLICAS" "$root_password" || exit 1
  echo ""

  # Step 5: Validate
  log_info "[5/5] Validating final state..."
  validate_final_state "$TARGET_REPLICAS" "$root_password" || exit 1
  echo ""

  # Success
  section "BOOTSTRAP RECOVERY COMPLETE"
  log_success "Cluster scaled to $TARGET_REPLICAS replicas"
  log_success "All nodes synced and healthy"
  echo ""
  log_info "Next steps:"
  log_muted "  • Monitor cluster: oc exec deployment/pod-health-monitor -n $NAMESPACE -- /scripts/utils/galera-inspect.sh"
  log_muted "  • Verify application connectivity"
  echo ""

  exit 0
}

# Run main
main "$@"
#!/bin/bash
# =============================================================================
# galera-bootstrap.sh - Comprehensive Galera Cluster Bootstrap Recovery
# =============================================================================
# Purpose: Bootstrap MariaDB Galera cluster from split-brain or complete outage
#
# Usage:
#   # Interactive mode (prompts for confirmation)
#   ./galera-bootstrap.sh --namespace 950003-prod
#
#   # Non-interactive mode (for automation/PowerShell wrappers)
#   ./galera-bootstrap.sh --namespace 950003-prod --target-replicas 5 --non-interactive --force
#
#   # Analyze only (no changes)
#   ./galera-bootstrap.sh --namespace 950003-prod --analyze-only
#
# Arguments:
#   --namespace <ns>          Required: OpenShift namespace
#   --target-replicas <n>     Optional: Target replica count (auto-detects from CSV/annotation)
#   --bootstrap-node <name>   Optional: Override automatic node selection
#   --non-interactive         Optional: No prompts (fails if required input missing)
#   --force                   Optional: Skip confirmation prompts
#   --analyze-only            Optional: Show analysis and exit (no changes)
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
TARGET_REPLICAS=""
BOOTSTRAP_NODE=""
NON_INTERACTIVE=false
FORCE=false
ANALYZE_ONLY=false

usage() {
  cat <<EOF
Bootstrap MariaDB Galera cluster from split-brain or complete outage

Usage:
  $(basename "$0") --namespace <ns> [OPTIONS]

Required:
  --namespace <ns>          OpenShift namespace (e.g., 950003-prod)

Optional:
  --target-replicas <n>     Target replica count (default: auto-detect from CSV/annotation)
  --bootstrap-node <name>   Override automatic node selection (default: highest seqno)
  --non-interactive         No prompts, fail if required input missing
  --force                   Skip confirmation prompts (DANGEROUS)
  --analyze-only            Show analysis and exit (no changes)

Examples:
  # Interactive analysis (safe)
  $(basename "$0") --namespace 950003-prod --analyze-only

  # Interactive bootstrap (prompts for confirmation)
  $(basename "$0") --namespace 950003-prod

  # Non-interactive bootstrap (for automation)
  $(basename "$0") --namespace 950003-prod --target-replicas 5 --non-interactive --force

Exit Codes:
  0 = Success
  1 = Error
  2 = Missing required parameter

EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      NAMESPACE="$2"
      shift 2
      ;;
    --target-replicas)
      TARGET_REPLICAS="$2"
      shift 2
      ;;
    --bootstrap-node)
      BOOTSTRAP_NODE="$2"
      shift 2
      ;;
    --non-interactive)
      NON_INTERACTIVE=true
      shift
      ;;
    --force)
      FORCE=true
      shift
      ;;
    --analyze-only)
      ANALYZE_ONLY=true
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
  echo ""
  usage
fi

# Set defaults
STS_NAME="mariadb-galera"

# =============================================================================
# INITIALIZATION
# =============================================================================

log_info "Galera Cluster Bootstrap Recovery"
echo "  Namespace: $NAMESPACE"
echo "  StatefulSet: $STS_NAME"
echo "  Mode: $([ "$ANALYZE_ONLY" = true ] && echo "ANALYZE-ONLY" || echo "BOOTSTRAP")"
echo ""

# Setup authentication
galera_setup_auth "$NAMESPACE"

# Get root password
log_info "Retrieving database credentials..."
ROOT_PASSWORD=$(galera_get_root_password "$NAMESPACE")
if [[ $? -ne 0 || -z "$ROOT_PASSWORD" ]]; then
  log_error "Failed to get database root password"
  log_debug "  Check secret 'mariadb-galera' in namespace '$NAMESPACE'"
  log_debug "  Or set DB_ROOT_PASSWORD environment variable"
  exit 1
fi
log_success "Credentials retrieved"
echo ""

# Get target replicas
if [[ -z "$TARGET_REPLICAS" ]]; then
  log_info "Detecting target replica count..."
  TARGET_REPLICAS=$(galera_get_target_replicas "$NAMESPACE" "$STS_NAME")
  log_success "Target replicas: $TARGET_REPLICAS"
else
  log_info "Using provided target replicas: $TARGET_REPLICAS"
fi
echo ""

# =============================================================================
# GRASTATE ANALYSIS
# =============================================================================

analyze_grastate() {
  log_info "Analyzing grastate.dat from all nodes..."

  # Get running pods
  local pods
  pods=$(oc get pods -l "app.kubernetes.io/name=$STS_NAME" -n "$NAMESPACE" \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

  local pod_count=0
  if [[ -n "$pods" ]]; then
    pod_count=$(echo "$pods" | wc -w)
  fi

  # Array to store grastate data: "node_name|seqno|uuid|safe_to_bootstrap"
  GRASTATE_DATA=()

  if [[ $pod_count -gt 0 ]]; then
    log_debug "Reading from $pod_count running pod(s)..."

    for pod in $pods; do
      log_debug "  Checking $pod..."

      local grastate_output
      grastate_output=$(galera_read_grastate_from_pod "$pod" "$NAMESPACE")

      if [[ $? -eq 0 ]]; then
        # Parse output
        local seqno uuid safe_to_bootstrap
        eval "$grastate_output"

        GRASTATE_DATA+=("$pod|$seqno|$uuid|$safe_to_bootstrap")
      else
        log_warning "  Failed to read grastate.dat from $pod"
        GRASTATE_DATA+=("$pod|-999||0")  # Mark as unavailable
      fi
    done
  else
    log_debug "No running pods, reading from PVCs..."

    # Get all PVCs
    local pvcs
    pvcs=$(oc get pvc -n "$NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | \
           tr ' ' '\n' | grep "^data-$STS_NAME-")

    if [[ -z "$pvcs" ]]; then
      log_error "No running pods and no PVCs found"
      return 1
    fi

    for pvc in $pvcs; do
      # Extract node index from PVC name (data-mariadb-galera-0 -> 0)
      if [[ "$pvc" =~ data-${STS_NAME}-([0-9]+) ]]; then
        local node_index="${BASH_REMATCH[1]}"
        local node_name="$STS_NAME-$node_index"

        log_debug "  Checking $pvc (node: $node_name)..."

        local grastate_output
        grastate_output=$(galera_read_grastate_from_pvc "$pvc" "$NAMESPACE")

        if [[ $? -eq 0 ]]; then
          local seqno uuid safe_to_bootstrap
          eval "$grastate_output"

          GRASTATE_DATA+=("$node_name|$seqno|$uuid|$safe_to_bootstrap")
        else
          log_warning "  Failed to read grastate.dat from $pvc"
          GRASTATE_DATA+=("$node_name|-999||0")
        fi
      fi
    done
  fi

  if [[ ${#GRASTATE_DATA[@]} -eq 0 ]]; then
    log_error "Could not read grastate.dat from any node"
    return 1
  fi

  log_success "Analyzed ${#GRASTATE_DATA[@]} node(s)"
  return 0
}

find_best_bootstrap_node() {
  local max_seqno=-99999999
  local best_node=""
  local all_negative_one=true
  local safe_node=""

  # Find highest seqno
  for entry in "${GRASTATE_DATA[@]}"; do
    IFS='|' read -r node seqno uuid safe_to_bootstrap <<< "$entry"

    # Skip unavailable nodes
    if [[ "$seqno" == "-999" ]]; then
      continue
    fi

    # Track if all nodes have seqno=-1
    if [[ "$seqno" != "-1" ]]; then
      all_negative_one=false
    fi

    # Find highest seqno
    if [[ "$seqno" -gt "$max_seqno" ]]; then
      max_seqno="$seqno"
      best_node="$node"
    fi

    # Track safe_to_bootstrap=1 node
    if [[ "$safe_to_bootstrap" == "1" && -z "$safe_node" ]]; then
      safe_node="$node"
    fi
  done

  # Handle edge case: all seqno=-1 (unclean shutdown)
  if [[ "$all_negative_one" == "true" ]]; then
    log_warning "All nodes have seqno=-1 (unclean shutdown)"

    if [[ -n "$safe_node" ]]; then
      log_info "  Using safe_to_bootstrap=1 node: $safe_node"
      echo "$safe_node"
      return 0
    else
      log_warning "  No safe_to_bootstrap flag found, defaulting to ${STS_NAME}-0"
      echo "${STS_NAME}-0"
      return 0
    fi
  fi

  # Normal case: use highest seqno
  if [[ -n "$best_node" ]]; then
    echo "$best_node"
    return 0
  fi

  # Fallback
  log_warning "Could not determine best bootstrap node, defaulting to ${STS_NAME}-0"
  echo "${STS_NAME}-0"
  return 0
}

display_analysis() {
  echo ""
  echo "======================================================================"
  echo "  GRASTATE ANALYSIS"
  echo "======================================================================"
  echo ""

  for entry in "${GRASTATE_DATA[@]}"; do
    IFS='|' read -r node seqno uuid safe_to_bootstrap <<< "$entry"

    echo "  Node: $node"

    if [[ "$seqno" == "-999" ]]; then
      echo "    Status: UNAVAILABLE"
    else
      echo "    seqno: $seqno"
      echo "    uuid: ${uuid:-N/A}"
      echo "    safe_to_bootstrap: $safe_to_bootstrap"
    fi

    echo ""
  done

  echo "======================================================================"
  echo "  RECOMMENDATION"
  echo "======================================================================"
  echo ""
  echo "  Bootstrap node: $RECOMMENDED_NODE"
  echo "  Target replicas: $TARGET_REPLICAS"
  echo ""
}

# =============================================================================
# BOOTSTRAP OPERATIONS
# =============================================================================

scale_to_zero() {
  log_info "[1/7] Scaling StatefulSet to 0..."

  oc scale statefulset "$STS_NAME" --replicas=0 -n "$NAMESPACE" >/dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    log_error "Failed to scale down StatefulSet"
    return 1
  fi

  log_debug "  Waiting for pods to terminate..."
  sleep 15

  log_success "All pods terminated"
  return 0
}

bootstrap_from_node() {
  local bootstrap_node="$1"

  # NOTE: This implementation only supports bootstrapping from pod-0
  # Bootstrapping from non-pod-0 requires PVC swapping (advanced operation)
  if [[ "$bootstrap_node" != "${STS_NAME}-0" ]]; then
    log_warning "Bootstrap from non-pod-0 not yet implemented"
    log_info "  Defaulting to ${STS_NAME}-0"
    bootstrap_node="${STS_NAME}-0"
  fi

  log_info "[2/7] Bootstrapping from $bootstrap_node..."

  # Scale to 1
  oc scale statefulset "$STS_NAME" --replicas=1 -n "$NAMESPACE" >/dev/null 2>&1

  if [[ $? -ne 0 ]]; then
    log_error "Failed to scale to 1"
    return 1
  fi

  log_debug "  Waiting for pod to start..."

  # Wait for pod Running
  if ! galera_wait_for_pod_running "${STS_NAME}-0" "$NAMESPACE" 300; then
    log_error "Pod did not start within timeout"
    log_debug "  Check logs: oc logs ${STS_NAME}-0 -n $NAMESPACE"
    return 1
  fi

  log_debug "  Verifying MariaDB connectivity..."

  # Wait for MariaDB Primary status
  if ! galera_wait_for_sync "${STS_NAME}-0" "$NAMESPACE" "$ROOT_PASSWORD" 1 150; then
    log_error "MariaDB did not become accessible"
    log_debug "  Check logs: oc logs ${STS_NAME}-0 -n $NAMESPACE"
    return 1
  fi

  log_success "Bootstrap successful (cluster status: Primary)"
  return 0
}

verify_cluster_address() {
  log_info "[3/7] Verifying cluster discovery configuration..."

  # Call galera-fix-cluster-address.sh
  local fix_script="$SCRIPT_DIR/galera-fix-cluster-address.sh"

  if [[ ! -f "$fix_script" ]]; then
    log_warning "Cluster address fix script not found, skipping"
    return 0
  fi

  bash "$fix_script" "$NAMESPACE" "$STS_NAME" --fix >/dev/null 2>&1
  local exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    log_success "Cluster address configuration verified"
  elif [[ $exit_code -eq 1 ]]; then
    log_warning "Cluster address configuration fixed"
    sleep 3
  else
    log_warning "Cluster address check returned code: $exit_code"
    log_debug "  Continuing, but scale-up may fail"
  fi

  return 0
}

scale_up_gradually() {
  log_info "[4/7] Scaling up gradually (1→$TARGET_REPLICAS)..."

  for ((i=2; i<=TARGET_REPLICAS; i++)); do
    local pod_name="${STS_NAME}-$((i-1))"

    log_debug "  Scaling to $i replicas..."

    oc scale statefulset "$STS_NAME" --replicas="$i" -n "$NAMESPACE" >/dev/null 2>&1

    if [[ $? -ne 0 ]]; then
      log_error "Failed to scale to $i"
      return 1
    fi

    log_debug "    Waiting for $pod_name to join..."

    # Wait for pod Running
    if ! galera_wait_for_pod_running "$pod_name" "$NAMESPACE" 300; then
      log_error "$pod_name did not start"
      log_debug "  Check StatefulSet: oc describe statefulset $STS_NAME -n $NAMESPACE"
      return 1
    fi

    # Wait for sync
    if ! galera_wait_for_sync "$pod_name" "$NAMESPACE" "$ROOT_PASSWORD" "$i" 150; then
      log_error "$pod_name did not sync"

      # Get current state for debugging
      local health_output
      health_output=$(galera_check_cluster_health "$pod_name" "$NAMESPACE" "$ROOT_PASSWORD")

      if [[ $? -eq 0 ]]; then
        eval "$health_output"
        log_debug "  Current state: $local_state"
        log_debug "  Cluster size: $cluster_size"
      fi

      return 1
    fi

    log_success "  $pod_name synced (cluster size: $i)"
  done

  log_success "Scaled to $TARGET_REPLICAS replicas"
  return 0
}

validate_final_state() {
  log_info "[5/7] Validating final cluster state..."

  # Check all pods are in Primary state with same UUID
  local uuids=()
  local all_primary=true

  for ((i=0; i<TARGET_REPLICAS; i++)); do
    local pod_name="${STS_NAME}-$i"

    # Get UUID
    local uuid
    uuid=$(oc exec "$pod_name" -n "$NAMESPACE" -c mariadb-galera -- \
      mysql -uroot -p"$ROOT_PASSWORD" -sN \
      -e "SHOW STATUS LIKE 'wsrep_cluster_state_uuid';" 2>/dev/null | awk '{print $2}')

    if [[ -n "$uuid" ]]; then
      uuids+=("$uuid")
    fi

    # Check Primary status
    local health_output
    health_output=$(galera_check_cluster_health "$pod_name" "$NAMESPACE" "$ROOT_PASSWORD")

    if [[ $? -eq 0 ]]; then
      eval "$health_output"

      if [[ "$cluster_status" != "Primary" ]]; then
        all_primary=false
        log_warning "  $pod_name: $cluster_status (expected: Primary)"
      fi
    else
      all_primary=false
      log_warning "  $pod_name: Health check failed"
    fi
  done

  # Check UUID consistency
  local unique_uuids
  unique_uuids=$(printf '%s\n' "${uuids[@]}" | sort -u | wc -l)

  if [[ $unique_uuids -ne 1 ]]; then
    log_error "Multiple cluster UUIDs detected (split-brain still present)"
    log_debug "  UUIDs: ${uuids[*]}"
    return 1
  fi

  if [[ "$all_primary" == "false" ]]; then
    log_error "Not all nodes in Primary state"
    return 1
  fi

  log_success "All nodes Primary with same UUID"
  return 0
}

# =============================================================================
# MAIN ORCHESTRATION
# =============================================================================

main() {
  # Step 1: Analyze grastate
  if ! analyze_grastate; then
    exit 1
  fi

  # Step 2: Find best bootstrap node
  if [[ -z "$BOOTSTRAP_NODE" ]]; then
    RECOMMENDED_NODE=$(find_best_bootstrap_node)
  else
    RECOMMENDED_NODE="$BOOTSTRAP_NODE"
    log_info "Using provided bootstrap node: $RECOMMENDED_NODE"
  fi

  # Display analysis
  display_analysis

  # If analyze-only, exit here
  if [[ "$ANALYZE_ONLY" == "true" ]]; then
    log_info "Analysis complete (--analyze-only mode)"
    exit 0
  fi

  # Confirmation prompt
  if [[ "$FORCE" == "false" ]]; then
    echo "======================================================================"
    echo "  CONFIRMATION REQUIRED"
    echo "======================================================================"
    echo ""
    log_warning "You are about to bootstrap the Galera cluster"
    echo "  Namespace: $NAMESPACE"
    echo "  Bootstrap node: $RECOMMENDED_NODE"
    echo "  Target replicas: $TARGET_REPLICAS"
    echo ""
    echo "  This will:"
    echo "    1. Scale StatefulSet to 0 (graceful shutdown)"
    echo "    2. Bootstrap from $RECOMMENDED_NODE"
    echo "    3. Verify cluster address configuration"
    echo "    4. Scale up gradually (1→2→3→...→$TARGET_REPLICAS)"
    echo "    5. Validate final state"
    echo ""
    log_error "⚠️  DANGER: Bootstrapping from wrong node can cause data loss"
    echo ""

    if [[ "$NON_INTERACTIVE" == "true" ]]; then
      log_error "Non-interactive mode requires --force flag for confirmation"
      exit 2
    fi

    read -p "Type 'BOOTSTRAP' to confirm (or anything else to cancel): " confirmation

    if [[ "$confirmation" != "BOOTSTRAP" ]]; then
      log_info "Bootstrap cancelled by user"
      exit 0
    fi

    echo ""
  fi

  # Execute bootstrap
  log_info "Starting bootstrap recovery..."
  echo ""

  if ! scale_to_zero; then
    exit 1
  fi

  echo ""

  # NOTE: PVC deletion removed - handled by separate utility if needed
  # See: galera-delete-pvcs.sh (not called by default)

  if ! bootstrap_from_node "$RECOMMENDED_NODE"; then
    exit 1
  fi

  echo ""

  if ! verify_cluster_address; then
    exit 1
  fi

  echo ""

  if ! scale_up_gradually; then
    exit 1
  fi

  echo ""

  if ! validate_final_state; then
    log_warning "Cluster may not be fully healthy - manual verification recommended"
  fi

  echo ""
  echo "======================================================================"
  echo "  BOOTSTRAP RECOVERY COMPLETE"
  echo "======================================================================"
  echo ""
  log_success "Cluster scaled to $TARGET_REPLICAS replicas"
  log_success "All nodes synced and healthy"
  echo ""
  echo "Next steps:"
  echo "  1. Deploy timeout configuration to prevent future split-brain:"
  echo "     ./scripts/deploy-galera-timeouts.ps1 -Namespace $NAMESPACE"
  echo ""
  echo "  2. Monitor cluster health:"
  echo "     oc exec deployment/pod-health-monitor -n $NAMESPACE -- /scripts/utils/galera-inspect.sh"
  echo ""
}

# Run main
main
