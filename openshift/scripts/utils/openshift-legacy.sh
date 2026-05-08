#!/bin/bash

# OpenShift Utilities Module
# Contains core OpenShift operations, resource management, maintenance mode,
# secret management, logging, and validation functions
#
# NOTE: Many functions have been extracted to modular utilities:
#   - Cluster health: cluster-health.sh (check_cluster_health, show_cluster_events, etc.)
#   - Validation: validation.sh (get_pods_for_resource, debug_deployment_pods, etc.)
#   - Monitoring: monitoring.sh (wait_for, handle_job_status, etc.)
#   - Secrets: secrets.sh (get_secret_value, create_or_update_secret, etc.)
#   - PVC: pvc.sh (expand_pvc, expand_statefulset_pvcs, etc.)
#
# This file remains for:
#   - Resource management (scaling, Galera-aware scaling)
#   - HPA creation
#   - Maintenance mode
#   - Legacy compatibility

# =============================================================================
# SCALING AND RESOURCE MANAGEMENT
# =============================================================================

# Define error handling functions
delete_pod() {
  local pod=$1
  echo "Restarting (deleting) pod..."
  delete_resource_if_exists pod $pod
}

# Unified resource scaling function
scale_resource() {
  local type="$1"
  local resource_name="$2"
  local target_replicas="$3"
  local max_replicas="${4:-$target_replicas}"  # Default to target_replicas if not specified
  local namespace="${5:-$DEPLOY_NAMESPACE}"
  local timeout="${6:-300s}"
  local enable_hpa="${7:-false}"  # New flag to control HPA behavior

  # Standardize resource type names
  case "$type" in
    "sts") type="statefulset" ;;
    "deploy") type="deployment" ;;
  esac

  # Check if the resource exists
  if ! oc get "$type" "$resource_name" -n "$namespace" &> /dev/null; then
    echo "⚠️ $type/$resource_name does not exist in namespace $namespace"
    return 1
  fi

  echo "🔄 Scaling $type/$resource_name to $target_replicas replicas (max: $max_replicas)..."

  # Handle HPA for deployments (backward compatibility with scale_deployment)
  if [[ "$type" == "deployment" && "$enable_hpa" == "true" ]]; then
    # Remove existing autoscaler if it exists
    if oc get hpa "$resource_name" -n "$namespace" &> /dev/null; then
      echo "Removing existing HorizontalPodAutoscaler for $resource_name"
      oc delete hpa "$resource_name" -n "$namespace" 2>/dev/null || true
    fi

    sleep 10
  fi

  # Perform the scaling operation
  if ! oc scale "$type" "$resource_name" --replicas="$target_replicas" -n "$namespace"; then
    echo "❌ Failed to scale $type/$resource_name to $target_replicas replicas"
    return 1
  fi

  # Add HPA if requested and max_replicas > target_replicas (backward compatibility)
  if [[ "$type" == "deployment" && "$enable_hpa" == "true" && $max_replicas -gt $target_replicas ]]; then
    echo "Creating HorizontalPodAutoscaler: min=$target_replicas, max=$max_replicas"
    oc autoscale deployment "$resource_name" --min="$target_replicas" --max="$max_replicas" --cpu-percent=80 -n "$namespace"

    # Apply deployment strategy patches for better rolling updates
    oc patch deployment "$resource_name" -n "$namespace" -p='{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"100%","maxUnavailable":"33%"}}}}' 2>/dev/null || true
  fi

  # Wait for scaling to complete
  echo "⏳ Waiting for $type/$resource_name to scale to $target_replicas replicas..."

  if [[ "$target_replicas" == "0" ]]; then
    # Scaling down - wait for pods to terminate
    if wait_for "$type/$resource_name" "ready" "$timeout" "down"; then
      echo "✅ $type/$resource_name successfully scaled down to 0"
      return 0
    else
      echo "⚠️ Timeout waiting for $type/$resource_name to scale down"
      return 1
    fi
  else
    # Add fixed sleep for deployment stabilization (backward compatibility)
    if [[ "$enable_hpa" == "true" ]]; then
      sleep 20
    fi

    # Scaling up - wait for pods to be ready and error-free
    if wait_for_deployment_without_errors "$type/$resource_name"; then
      echo "✅ $type/$resource_name successfully scaled to $target_replicas replicas"
      return 0
    else
      echo "⚠️ $type/$resource_name scaled but pods have errors or timeout occurred"
      return 1
    fi
  fi
}

# Legacy wrapper for backward compatibility
scale_deployment() {
  local type="$1"
  local deployment="$2"
  local pod_count="$3"
  local max_pods="$4"

  # Call new unified function with HPA enabled
  scale_resource "$type" "$deployment" "$pod_count" "$max_pods" "$DEPLOY_NAMESPACE" "300s" "true"
}

# Convenience wrapper for simple scaling without HPA
scale_simple() {
  local type="$1"
  local resource_name="$2"
  local target_replicas="$3"
  local namespace="${4:-$DEPLOY_NAMESPACE}"
  local timeout="${5:-300s}"

  scale_resource "$type" "$resource_name" "$target_replicas" "$target_replicas" "$namespace" "$timeout" "false"
}

# =============================================================================
# Galera-Aware Scaling Function
# =============================================================================
# Scales Galera StatefulSets safely with:
# - Pre-flight cluster address verification
# - Incremental scale-up (1→2→3→...→N) with sync validation per node
# - Safe scale-down (leverages OrderedReady for reverse shutdown)
# - Split-brain prevention and health checks
#
# Parameters:
#   $1 - sts_name: Name of the StatefulSet (e.g., "mariadb-galera")
#   $2 - target_replicas: Desired number of replicas
#   $3 - namespace: Kubernetes namespace (optional, defaults to $DEPLOY_NAMESPACE)
#
# Returns:
#   0: Success
#   1: Failure (cluster address invalid, scaling failed, or health check failed)
#
# Links: docs/galera-deployment-best-practices.md#solution-4
# =============================================================================
scale_galera_statefulset() {
  local sts_name="$1"
  local target_replicas="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  log_header "Galera-Aware Scaling: $sts_name → $target_replicas replicas"

  # ============================================================
  # STEP 1: PRE-FLIGHT VERIFICATION
  # ============================================================
  log_info "Step 1/4: Pre-flight cluster address verification"

  # Source Galera utilities if not already loaded
  if ! command -v galera_verify_cluster_address &>/dev/null; then
    local galera_utils
    galera_utils="$(dirname "${BASH_SOURCE[0]}")/database.sh"
    if [[ -f "$galera_utils" ]]; then
      source "$galera_utils"
    else
      log_error "Cannot load Galera utilities from: $galera_utils"
      return 1
    fi
  fi

  # Verify cluster address before any scaling operations
  if ! galera_verify_cluster_address "$sts_name" "$namespace" "fix"; then
    log_error "Cluster address verification failed - aborting scale operation"
    log_error "Run galera-fix-cluster-address.sh manually to diagnose"
    return 1
  fi

  # ============================================================
  # STEP 2: DETERMINE SCALING DIRECTION
  # ============================================================
  log_info "Step 2/4: Determine scaling strategy"

  local current_replicas
  current_replicas=$(oc get sts/"$sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)

  if [[ -z "$current_replicas" ]]; then
    log_error "StatefulSet not found: $sts_name"
    return 1
  fi

  log_debug "  Current replicas: $current_replicas"
  log_debug "  Target replicas:  $target_replicas"

  if [[ "$current_replicas" -eq "$target_replicas" ]]; then
    log_success "Already at target replica count ($target_replicas)"
    return 0
  fi

  # ============================================================
  # STEP 3: EXECUTE SCALING OPERATION
  # ============================================================
  if [[ "$current_replicas" -lt "$target_replicas" ]]; then
    # ------------------------------------------------------
    # SCALE-UP: Incremental with sync validation
    # ------------------------------------------------------
    log_info "Step 3/4: Incremental scale-up ($current_replicas → $target_replicas)"
    log_warn "⚠️  This will add nodes one-by-one with Galera sync validation"

    for i in $(seq $((current_replicas + 1)) "$target_replicas"); do
      log_info "  ➤ Scaling to $i replicas..."

      # Scale to next replica count
      if ! oc scale sts/"$sts_name" --replicas="$i" -n "$namespace"; then
        log_error "Failed to scale to $i replicas"
        return 1
      fi

      # Wait for new pod to become Ready
      local new_pod="${sts_name}-$((i - 1))"
      log_debug "    Waiting for pod $new_pod to become Ready..."

      if ! oc wait --for=condition=Ready pod/"$new_pod" -n "$namespace" --timeout=300s 2>/dev/null; then
        log_error "Pod $new_pod failed to become Ready within 5 minutes"
        log_error "Check pod logs: oc logs $new_pod -n $namespace"
        return 1
      fi

      # Verify Galera cluster sync before continuing
      log_debug "    Verifying Galera sync at $i nodes..."

      if ! galera_wait_for_sync "$sts_name" 30 10 "$i"; then
        log_error "Galera cluster failed to sync after adding pod $new_pod"
        log_error "Cluster may be in split-brain or SST is failing"
        log_error "Check Galera status: oc exec $new_pod -n $namespace -- mysql -e 'SHOW STATUS LIKE \"wsrep%\"'"
        return 1
      fi

      log_success "  ✔️  Pod $new_pod joined cluster successfully"
    done

    log_success "Scale-up complete: $current_replicas → $target_replicas"

  elif [[ "$current_replicas" -gt "$target_replicas" ]]; then
    # ------------------------------------------------------
    # SCALE-DOWN: Safe (OrderedReady handles reverse order)
    # ------------------------------------------------------
    log_info "Step 3/4: Scale-down ($current_replicas → $target_replicas)"
    log_debug "  OrderedReady ensures pods shut down in reverse order (N→...→3→2→1)"
    log_debug "  Pod-0 (primary) will remain untouched"

    if ! oc scale sts/"$sts_name" --replicas="$target_replicas" -n "$namespace"; then
      log_error "Failed to scale down to $target_replicas"
      return 1
    fi

    # Wait for scale-down to complete
    log_debug "  Waiting for excess pods to terminate..."
    for i in $(seq "$target_replicas" $((current_replicas - 1))); do
      local removing_pod="${sts_name}-${i}"
      oc wait --for=delete pod/"$removing_pod" -n "$namespace" --timeout=300s 2>/dev/null || true
    done

    log_success "Scale-down complete: $current_replicas → $target_replicas"
  fi

  # ============================================================
  # STEP 4: POST-SCALING HEALTH CHECK
  # ============================================================
  log_info "Step 4/4: Final health verification"

  # Wait a moment for cluster to stabilize
  sleep 5

  # Verify all pods are Ready
  local ready_pods
  ready_pods=$(oc get pods -l "app.kubernetes.io/name=${sts_name}" -n "$namespace" -o jsonpath='{.items[?(@.status.conditions[?(@.type=="Ready" && @.status=="True")])].metadata.name}' | wc -w)

  if [[ "$ready_pods" -ne "$target_replicas" ]]; then
    log_error "Health check failed: Expected $target_replicas Ready pods, found $ready_pods"
    return 1
  fi

  # Verify Galera cluster health
  if ! check_galera_cluster_health "app.kubernetes.io/name=$sts_name" "$namespace" "$target_replicas"; then
    log_error "Galera cluster health check failed after scaling"
    log_error "Run: oc exec ${sts_name}-0 -n $namespace -- mysql -e 'SHOW STATUS LIKE \"wsrep%\"'"
    return 1
  fi

  log_success "✅ Galera cluster scaled successfully to $target_replicas replicas"
  log_success "   Cluster is healthy and all nodes are in sync"
  return 0
}

# Function to check if a resource exists
resource_exists() {
  local resource_type=$1
  local resource_name=$2

  if oc get $resource_type $resource_name &> /dev/null; then
    return 0
  else
    return 1
  fi
}

# Wait for deployment to scale down [to 0 replicas]
wait_for_scale_down() {
  local resource=$1 # e.g., deployment/php
  local max_retries=${2:-30}
  local wait_time=${3:-10}
  local retry_count=0

  echo "Waiting for $resource to scale down to 0 replicas..."

  while true; do
    # Get the list of pods for the resource
    local pods=$(oc get pods --selector=deployment=${resource##*/} -o jsonpath='{.items[*].metadata.name}')

    if [[ -z "$pods" ]]; then
      echo "✔️ All pods for $resource have been terminated."
      return 0
    else
      echo "Pods still exist for $resource: $pods. Retrying..."
    fi

    # Retry logic
    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Timeout waiting for $resource to scale down. Exiting..."
      return 1
    fi

    sleep $wait_time
  done
}

# Function to delete a resource if it exists
delete_resource_if_exists() {
  local resource_type=$1
  local resource_name=$2

  echo "Checking if $resource_type exists: $resource_name"

  # Use oc get to check if the resource exists
  if oc get $resource_type $resource_name &> /dev/null; then
    echo "Deleting existing $resource_type: $resource_name"
    oc delete $resource_type $resource_name
  else
    echo "$resource_type does not exist: $resource_name"
  fi
}

# Function to deploy a resource from a template
deploy_resource_from_template() {
  local template_file=$1
  shift
  local params=("$@")

  # Construct the oc process command with parameters
  local process_cmd="oc process -f $template_file"
  for param in "${params[@]}"; do
    process_cmd+=" -p \"$param\""
  done

  echo "Deploying resource from template: $template_file"

  # Process the template and print the output for debugging
  local processed_template
  processed_template=$(eval $process_cmd)

  # Extract the deployment name from the processed template
  local deployment_name=$(echo "$processed_template" | jq -r '.items[] | select(.kind == "Deployment") | .metadata.name')

  # Delete the existing deployment if it exists
  if [ -n "$deployment_name" ]; then
    delete_resource_if_exists deployment $deployment_name
  fi

  # Apply the processed template
  echo "$processed_template" | oc apply -f -

  echo "Resource deployed from template: $template_file"
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Ensure openShift resource values are valid
# Returns: "<value><unit>" for positive integers, "0" for zero, "null" for empty/invalid
validate_and_format_resource_value() {
  local value=$1
  local unit=$2

  # Check if the value is a valid positive integer (1, 25, 50, 100, 1500, etc.)
  if [[ $value =~ ^[1-9][0-9]*$ ]]; then
    echo "${value}${unit}"
  elif [[ $value == "0" || $value == 0 ]]; then
    echo "0"
  else
    echo "null"
  fi
}

# Platform detection functions
is_openshift() {
  [[ -n "$DEPLOY_NAMESPACE" ]]
}

is_docker() {
  [[ -z "$DEPLOY_NAMESPACE" ]]
}

# Platform-specific execution
platform_exec() {
  local pod_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  shift 2
  local command="$*"

  if is_openshift; then
    oc exec -n "$namespace" "$pod_name" -- bash -c "$command"
  elif is_docker; then
    docker exec "$pod_name" bash -c "$command"
  else
    echo "❌ Unknown platform"
    return 1
  fi
}

# Platform-specific copy operations
platform_cp() {
  local source="$1"
  local destination="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  if is_openshift; then
    oc cp -n "$namespace" "$source" "$destination"
  elif is_docker; then
    docker cp "$source" "$destination"
  else
    echo "❌ Unknown platform"
    return 1
  fi
}

# Generic function to get pods for a resource
get_pods_for_resource() {
  local resource="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Split the resource into type and name
  local resource_type=${resource%%/*}
  local resource_name=${resource##*/}

  # Validate that resource was properly split
  if [[ -z "$resource_type" || -z "$resource_name" || "$resource_type" == "$resource" ]]; then
    echo "❌ Invalid resource format: $resource. Expected format: <type>/<name>" >&2
    return 1
  fi

  # Handle full API resource names (e.g., deployment.apps -> deployment)
  case "$resource_type" in
    "deployment.apps" | "deployments.apps") resource_type="deployment" ;;
    "statefulset.apps" | "statefulsets.apps") resource_type="statefulset" ;;
    "service.v1" | "services.v1") resource_type="service" ;;
    "job.batch" | "jobs.batch") resource_type="job" ;;
  esac

  # Get pods based on resource type using proper selectors
  case "$resource_type" in
    "deployment")
      # For deployments, get the selector labels from the deployment itself
      local selector_labels
      selector_labels=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)

      if [[ -n "$selector_labels" && "$selector_labels" != "{}" ]]; then
        # Try to parse the matchLabels JSON and convert to label selector format
        local selector_string=""

        # First try with jq (this will work in Linux/OpenShift environment)
        if command -v jq >/dev/null 2>&1; then
          selector_string=$(echo "$selector_labels" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || echo "")
        fi

        # If jq failed or not available, use simple bash parsing for common patterns
        if [[ -z "$selector_string" || "$selector_string" == "null" ]]; then
          # Handle simple cases like {"deployment":"name"} or {"app":"name"}
          if [[ "$selector_labels" =~ \"deployment\":\"([^\"]+)\" ]]; then
            selector_string="deployment=${BASH_REMATCH[1]}"
          elif [[ "$selector_labels" =~ \"app\":\"([^\"]+)\" ]]; then
            selector_string="app=${BASH_REMATCH[1]}"
          fi
        fi

        # Use the parsed selector if we got one
        if [[ -n "$selector_string" && "$selector_string" != "null" ]]; then
          oc get pods -l "$selector_string" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
        else
          # Fallback to common deployment patterns
          local pods
          pods=$(oc get pods -l app="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          if [[ -z "$pods" ]]; then
            pods=$(oc get pods -l deployment="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          fi
          echo "$pods"
        fi
      else
        # No selector labels found, use common patterns
        local pods
        pods=$(oc get pods -l app="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -z "$pods" ]]; then
          pods=$(oc get pods -l deployment="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        fi
        echo "$pods"
      fi
      ;;
    "statefulset")
      # For statefulsets, get the selector labels from the statefulset itself
      local selector_labels
      selector_labels=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)

      if [[ -n "$selector_labels" && "$selector_labels" != "{}" ]]; then
        local selector_string=""

        # Try with jq first (works in Linux/OpenShift)
        if command -v jq >/dev/null 2>&1; then
          selector_string=$(echo "$selector_labels" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || echo "")
        fi

        # Bash parsing fallback for common patterns
        if [[ -z "$selector_string" || "$selector_string" == "null" ]]; then
          if [[ "$selector_labels" =~ \"app\.kubernetes\.io/name\":\"([^\"]+)\" ]]; then
            selector_string="app.kubernetes.io/name=${BASH_REMATCH[1]}"
          elif [[ "$selector_labels" =~ \"app\":\"([^\"]+)\" ]]; then
            selector_string="app=${BASH_REMATCH[1]}"
          fi
        fi

        if [[ -n "$selector_string" && "$selector_string" != "null" ]]; then
          oc get pods -l "$selector_string" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
        else
          # Fallback to common statefulset patterns
          local pods
          pods=$(oc get pods -l app.kubernetes.io/name="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          if [[ -z "$pods" ]]; then
            pods=$(oc get pods -l app="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          fi
          echo "$pods"
        fi
      else
        # No selector labels, use common patterns
        local pods
        pods=$(oc get pods -l app.kubernetes.io/name="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -z "$pods" ]]; then
          pods=$(oc get pods -l app="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        fi
        echo "$pods"
      fi
      ;;
    "job")
      oc get pods -l job-name="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
      ;;
    *)
      # Fallback: try multiple common selectors
      local pods

      # Try app label first
      pods=$(oc get pods -l app="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

      # Try app.kubernetes.io/name if app didn't work
      if [[ -z "$pods" ]]; then
        pods=$(oc get pods -l app.kubernetes.io/name="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      fi

      # Try deployment label if others didn't work
      if [[ -z "$pods" ]]; then
        pods=$(oc get pods -l deployment="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      fi

      # Try deploymentconfig label (OpenShift specific)
      if [[ -z "$pods" ]]; then
        pods=$(oc get pods -l deploymentconfig="$resource_name" -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      fi

      echo "$pods"
      ;;
  esac
}

# Debug function to troubleshoot pod discovery issues
debug_deployment_pods() {
  local deployment_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  log_info "🔍 Debug: Troubleshooting pod discovery for deployment: $deployment_name"

  # Check if deployment exists
  if ! oc get deployment "$deployment_name" -n "$namespace" &> /dev/null; then
    log_error "Deployment '$deployment_name' does not exist in namespace '$namespace'"
    return 1
  fi

  # Show deployment details
  log_info "Deployment details:"
  oc get deployment "$deployment_name" -n "$namespace" -o yaml | grep -A 10 -B 5 "matchLabels\|replicas\|selector"

  # Show selector labels
  echo ""

  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    log_debug "Deployment selector labels:"
    local selector_labels
    selector_labels=$(oc get deployment "$deployment_name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)
    log_debug "$selector_labels" | jq . 2>/dev/null || echo "$selector_labels"

    # Show all pods in namespace with their labels
    echo ""
    log_debug "All pods in namespace with 'maintenance' in name:"
    oc get pods -n "$namespace" -o wide | grep -i maintenance || echo "No pods found with 'maintenance' in name"

    # Show all pods with various label attempts
    echo ""
    echo "🔍 Pod discovery attempts:"

    echo "  1. Using app=$deployment_name:"
    oc get pods -l app="$deployment_name" -n "$namespace" -o name 2>/dev/null || echo "    No pods found"

    echo "  2. Using app.kubernetes.io/name=$deployment_name:"
    oc get pods -l app.kubernetes.io/name="$deployment_name" -n "$namespace" -o name 2>/dev/null || echo "    No pods found"

    echo "  3. Using deployment=$deployment_name:"
    oc get pods -l deployment="$deployment_name" -n "$namespace" -o name 2>/dev/null || echo "    No pods found"

    echo "  4. Using deploymentconfig=$deployment_name:"
    oc get pods -l deploymentconfig="$deployment_name" -n "$namespace" -o name 2>/dev/null || echo "    No pods found"
  fi

  # Try using actual selector from deployment
  if [[ -n "$selector_labels" && "$selector_labels" != "null" ]]; then
    if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
      echo "  5. Using deployment's actual selector:"
    fi
    local selector_string
    selector_string=$(echo "$selector_labels" | jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null)
    if [[ -n "$selector_string" && "$selector_string" != "null" ]]; then
      if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
        echo "    Selector: $selector_string"
        oc get pods -l "$selector_string" -n "$namespace" -o name 2>/dev/null || echo "    No pods found with actual selector"
      fi
    else
      log_warn "    Could not parse selector"
    fi
  fi
}

# Function to set resources for a deployment
set_resources() {
  local type=$1
  local deployment=$2
  local cpu_request=$3
  local mem_request=$4
  local cpu_limit=$5
  local mem_limit=$6

  log_info "Setting resources for $type/$deployment..."
  log_debug "CPU Request: $cpu_request"
  log_debug "Memory Request: $mem_request"
  log_debug "CPU Limit: $cpu_limit"
  log_debug "Memory Limit: $mem_limit"

  # Validate and format resource values
  cpu_request=$(validate_and_format_resource_value "$cpu_request" "m")
  mem_request=$(validate_and_format_resource_value "$mem_request" "Mi")
  cpu_limit=$(validate_and_format_resource_value "$cpu_limit" "m")
  mem_limit=$(validate_and_format_resource_value "$mem_limit" "Mi")

  # Resource limit philosophy (BC Gov Platform best practices):
  #
  # CPU LIMITS: Never set (0 in CSV = omit from spec)
  #   - CPU is compressible: kernel throttles under contention, doesn't kill
  #   - Bursting above request improves throughput when node has spare capacity
  #   - Requests guarantee minimum CPU for scheduling
  #
  # MEMORY LIMITS: Optional (0 in CSV = omit from spec)
  #   - Memory is incompressible: exceeding limit = OOMKill
  #   - Setting limit = request creates HARD CAP (no burst) → OOMKills during spikes
  #   - Omitting limit allows burst up to namespace quota (Burstable QoS)
  #   - Workloads with variable memory (PHP cache ops) should use 0 limit
  #   - Workloads with predictable memory can set explicit limits for safety
  #
  # When 0 is specified in CSV, it's treated as "intentionally unset" (not safety-forced to request).

  # Validate: request must not exceed limit when both are set.
  # If request > limit, auto-correct by raising the limit to match.
  local mem_req_num=${mem_request//[!0-9]/}
  local mem_lim_num=${mem_limit//[!0-9]/}
  if [[ "$mem_request" != "null" && "$mem_request" != "0" && \
        "$mem_limit" != "null" && "$mem_limit" != "0" && \
        -n "$mem_req_num" && -n "$mem_lim_num" && \
        "$mem_req_num" -gt "$mem_lim_num" ]]; then
    log_warn "Memory request (${mem_request}) exceeds limit (${mem_limit}) for $type/$deployment -- raising limit to match"
    mem_limit="$mem_request"
  fi

  local cpu_req_num=${cpu_request//[!0-9]/}
  local cpu_lim_num=${cpu_limit//[!0-9]/}
  if [[ "$cpu_request" != "null" && "$cpu_request" != "0" && \
        "$cpu_limit" != "null" && "$cpu_limit" != "0" && \
        -n "$cpu_req_num" && -n "$cpu_lim_num" && \
        "$cpu_req_num" -gt "$cpu_lim_num" ]]; then
    log_warn "CPU request (${cpu_request}) exceeds limit (${cpu_limit}) for $type/$deployment -- raising limit to match"
    cpu_limit="$cpu_request"
  fi

  # Build the desired resources JSON object.
  # Values of "0" or "null" are OMITTED — any resource field not listed here
  # will be REMOVED from the pod spec (declarative, not incremental).
  # This enables:
  #   - BestEffort QoS: all zeros → resources: {} → no requests or limits
  #   - CPU bursting:   cpu_limit=0 → no cpu limit → burst on spare capacity
  #   - Guaranteed QoS: all values set → requests and limits explicit
  local requests_parts=()
  local limits_parts=()

  if [[ "$cpu_request" != "null" && "$cpu_request" != "0" ]]; then
    requests_parts+=("\"cpu\":\"$cpu_request\"")
  fi
  if [[ "$mem_request" != "null" && "$mem_request" != "0" ]]; then
    requests_parts+=("\"memory\":\"$mem_request\"")
  fi
  if [[ "$cpu_limit" != "null" && "$cpu_limit" != "0" ]]; then
    limits_parts+=("\"cpu\":\"$cpu_limit\"")
  fi
  if [[ "$mem_limit" != "null" && "$mem_limit" != "0" ]]; then
    limits_parts+=("\"memory\":\"$mem_limit\"")
  fi

  local resources_obj="{}"
  local resources_parts=()
  if [[ ${#requests_parts[@]} -gt 0 ]]; then
    local req_json
    req_json=$(IFS=,; echo "${requests_parts[*]}")
    resources_parts+=("\"requests\":{$req_json}")
  fi
  if [[ ${#limits_parts[@]} -gt 0 ]]; then
    local lim_json
    lim_json=$(IFS=,; echo "${limits_parts[*]}")
    resources_parts+=("\"limits\":{$lim_json}")
  fi
  if [[ ${#resources_parts[@]} -gt 0 ]]; then
    local parts_json
    parts_json=$(IFS=,; echo "${resources_parts[*]}")
    resources_obj="{$parts_json}"
  fi

  # Determine QoS class for logging
  local qos="Burstable"
  if [[ ${#requests_parts[@]} -eq 0 && ${#limits_parts[@]} -eq 0 ]]; then
    qos="BestEffort"
  elif [[ "$cpu_request" == "$cpu_limit" && "$mem_request" == "$mem_limit" && \
          "$cpu_request" != "null" && "$cpu_request" != "0" && \
          "$mem_request" != "null" && "$mem_request" != "0" ]]; then
    qos="Guaranteed"
  fi

  # Apply declaratively via JSON patch — replaces the ENTIRE resources block
  # on every container. This ensures stale limits from prior Helm deploys or
  # manual patches are removed. Uses "add" op which creates-or-replaces.
  local num_containers
  num_containers=$(oc get "$type/$deployment" -n "$DEPLOY_NAMESPACE" \
    -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{"\n"}{end}' 2>/dev/null | grep -c . || echo "0")

  if [[ "$num_containers" -eq 0 ]]; then
    log_warn "No containers found for $type/$deployment — skipping resource update"
    return 0
  fi

  local patch_ops=()
  for ((i=0; i<num_containers; i++)); do
    patch_ops+=("{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/$i/resources\",\"value\":$resources_obj}")
  done
  local patch_json="[$(IFS=,; echo "${patch_ops[*]}")]"

  log_info "  Resources ($qos): $resources_obj (${num_containers} container(s))"
  log_debug "  Patch: $patch_json"

  if ! oc patch "$type/$deployment" -n "$DEPLOY_NAMESPACE" --type=json -p "$patch_json"; then
    log_warn "JSON patch failed for $type/$deployment — falling back to oc set resources"
    # Fallback: use oc set resources for positive values only (can't remove, but won't break)
    local cmd="oc set resources $type $deployment"
    local has_values=false
    if [[ ${#requests_parts[@]} -gt 0 ]]; then
      local req_csv=""
      [[ "$cpu_request" != "null" && "$cpu_request" != "0" ]] && req_csv+="cpu=${cpu_request}"
      if [[ "$mem_request" != "null" && "$mem_request" != "0" ]]; then
        [[ -n "$req_csv" ]] && req_csv+=","
        req_csv+="memory=${mem_request}"
      fi
      [[ -n "$req_csv" ]] && cmd+=" --requests=$req_csv" && has_values=true
    fi
    if [[ ${#limits_parts[@]} -gt 0 ]]; then
      local lim_csv=""
      [[ "$cpu_limit" != "null" && "$cpu_limit" != "0" ]] && lim_csv+="cpu=${cpu_limit}"
      if [[ "$mem_limit" != "null" && "$mem_limit" != "0" ]]; then
        [[ -n "$lim_csv" ]] && lim_csv+=","
        lim_csv+="memory=${mem_limit}"
      fi
      [[ -n "$lim_csv" ]] && cmd+=" --limits=$lim_csv" && has_values=true
    fi
    if $has_values; then
      log_debug "  Fallback: $cmd"
      $cmd
    fi
  fi
}

# Function to create HorizontalPodAutoscaler
create_hpa() {
  local name=$1
  local target=$2
  local min_replicas=$3
  local max_replicas=$4
  local avg_value=$5

  # Ensure avg_value includes "m" at the end
  if [[ ! $avg_value =~ m$ ]]; then
    avg_value="${avg_value}m"
  fi

  if [[ $avg_value == "0m" || $avg_value == "0.0m" || $max_replicas -le $min_replicas || $min_replicas == "0" ]]; then
    log_error "Invalid HPA values. Exiting..."
    return 1
  fi

  log_info "Creating HPA: $name > $target - Scale at $avg_value from $min_replicas to $max_replicas replicas"

  # Determine the kind of the target resource
  local kind="Deployment"
  if [[ $target == sts/* ]]; then
    kind="StatefulSet"
    target=${target#sts/}
  elif [[ $target == deployment/* ]]; then
    target=${target#deployment/}
  fi

  # Create a temporary template file
  cat <<EOF > hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $name
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: $kind
    name: $target
  minReplicas: $min_replicas
  maxReplicas: $max_replicas
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageValue: $avg_value
EOF

  # First, delete the HPA if it exists
  delete_resource_if_exists hpa $name

  log_info "Creating HPA from template:"
  oc create -f hpa.yaml

  wait_for_deployment_without_errors "$kind/$target"

  return 0
}

# =============================================================================
# RESOURCE UTILITY FUNCTIONS
# =============================================================================

# Function to normalize OpenShift resource names to proper format
# Handles conversion between "name" and "type/name" formats
normalize_resource_name() {
  local resource="$1"
  local default_type="${2:-deployment}"  # Default resource type if none specified
  local operation="${3:-format}"         # 'format' (ensure type/name) or 'extract' (get just name)

  if [[ -z "$resource" ]]; then
    log_error "normalize_resource_name: Resource name cannot be empty"
    return 1
  fi

  case "$operation" in
    "format")
      # Ensure resource is in "type/name" format
      if [[ "$resource" == */* ]]; then
        # Already has type, clean up any redundant API group suffixes
        local resource_type=${resource%%/*}
        local resource_name=${resource##*/}

        # Handle full API resource names (e.g., deployment.apps -> deployment)
        case "$resource_type" in
          "deployment.apps" | "deployments.apps") resource_type="deployment" ;;
          "statefulset.apps" | "statefulsets.apps") resource_type="statefulset" ;;
          "service.v1" | "services.v1") resource_type="service" ;;
          "job.batch" | "jobs.batch") resource_type="job" ;;
          "pod.v1" | "pods.v1") resource_type="pod" ;;
        esac

        echo "$resource_type/$resource_name"
      else
        # Just a name, prepend default type
        echo "$default_type/$resource"
      fi
      ;;
    "extract")
      # Extract just the name part (remove type prefix if present)
      if [[ "$resource" == */* ]]; then
        echo "${resource##*/}"
      else
        echo "$resource"
      fi
      ;;
    "type")
      # Extract just the type part
      if [[ "$resource" == */* ]]; then
        local resource_type=${resource%%/*}
        # Clean up API group suffixes
        case "$resource_type" in
          "deployment.apps" | "deployments.apps") echo "deployment" ;;
          "statefulset.apps" | "statefulsets.apps") echo "statefulset" ;;
          "service.v1" | "services.v1") echo "service" ;;
          "job.batch" | "jobs.batch") echo "job" ;;
          "pod.v1" | "pods.v1") echo "pod" ;;
          *) echo "$resource_type" ;;
        esac
      else
        echo "$default_type"
      fi
      ;;
    *)
      log_error "normalize_resource_name: Invalid operation '$operation'. Use 'format', 'extract', or 'type'"
      return 1
      ;;
  esac
}

# Function to validate resource name format for functions that require "type/name"
validate_resource_format() {
  local resource="$1"
  local function_name="${2:-unknown}"

  if [[ -z "$resource" ]]; then
    log_error "$function_name: Resource name cannot be empty"
    return 1
  fi

  if [[ "$resource" != */* ]]; then
    log_error "$function_name: Invalid resource format: $resource. Expected format: <type>/<name>"
    return 1
  fi

  return 0
}

# =============================================================================
# WAIT AND MONITORING FUNCTIONS
# =============================================================================

# Wait for a resource to deploy (or scale-down)
wait_for() {
  local resource=$1
  local condition=${2:-ready}
  local timeout=${3:-300s}
  local scale_direction=${4:-up}
  local max_retries=30
  local retry_count=0
  local wait_time=10

  # Wait to ensure the resource has had enough time to set the desired state
  sleep 10

  # Validate and normalize resource format
  if ! validate_resource_format "$resource" "wait_for"; then
    return 1
  fi

  # Extract resource type and name using utility function
  local resource_type=$(normalize_resource_name "$resource" "" "type")
  local resource_name=$(normalize_resource_name "$resource" "" "extract")

  # Convert timeout to seconds for calculation
  local timeout_seconds=$(echo $timeout | sed 's/[a-zA-Z]*//g')
  max_retries=$((timeout_seconds / wait_time))

  log_info "Waiting for $resource to be $condition ($scale_direction). Max time: $timeout..."

  # Check if the resource exists before attempting to scale
  if ! oc get $resource_type $resource_name &> /dev/null; then
    log_warn "$resource_type/$resource_name does not exist. Skipping..."
    return 0
  fi

  # Use cluster health monitoring if enabled via environment variable
  if [[ "${CLUSTER_HEALTH_MONITORING:-YES}" == "YES" && "$resource_type" != "job" ]]; then
    log_debug "🔄 Using centralized cluster health monitoring for $resource (CLUSTER_HEALTH_MONITORING=${CLUSTER_HEALTH_MONITORING})..."

    # Create a wrapper function for the actual wait logic
    eval "
    handle_deployment_status_wrapper() {
      handle_deployment_status \"$resource_name\" \"$condition\" \"$scale_direction\" 1 0 \"$wait_time\" \"$resource_type\"
      return \$?
    }
    "

    # Use centralized cluster health monitoring
    wait_with_cluster_monitoring "$resource_type" "$resource_name" "handle_deployment_status_wrapper" "$DEPLOY_NAMESPACE" "$timeout_seconds"
  else
    log_debug "🔄 Using traditional waiting for $resource (CLUSTER_HEALTH_MONITORING=${CLUSTER_HEALTH_MONITORING:-NO})..."
    # Use traditional waiting without cluster monitoring
    if [[ $resource_type == "job" ]]; then
      handle_job_status "$resource_name" "$max_retries" "$retry_count" "$wait_time"
    else
      handle_deployment_status "$resource_name" "$condition" "$scale_direction" "$max_retries" "$retry_count" "$wait_time" "$resource_type"
    fi
  fi
}

# Function to wait for all pods in a deployment or statefulset to be running and check for errors
wait_for_deployment_without_errors() {
  local resource=$1 # e.g., deployment/web
  local error_search_string=${2:-error}
  local error_handler=${3:-delete_pod}
  local max_retries=${4:-30}
  local wait_time=${5:-30}
  local enable_cluster_monitoring=${6:-true}  # New parameter to control cluster health monitoring

  # Split the resource into type and name
  local resource_type=${resource%%/*}
  local resource_name=${resource##*/}

  # Validate that resource was properly split
  if [[ -z "$resource_type" || -z "$resource_name" || "$resource_type" == "$resource" ]]; then
    log_error "Invalid resource format: $resource. Expected format: <type>/<name>"
    return 1
  fi

  # Handle full API resource names (e.g., deployment.apps -> deployment)
  case "$resource_type" in
    "deployment.apps" | "deployments.apps") resource_type="deployment" ;;
    "statefulset.apps" | "statefulsets.apps") resource_type="statefulset" ;;
    "service.v1" | "services.v1") resource_type="service" ;;
    "job.batch" | "jobs.batch") resource_type="job" ;;
  esac

  log_info "Waiting for $resource to be ready and error-free..."

  # Check if the resource exists
  if ! oc get $resource_type $resource_name &> /dev/null; then
    log_error "$resource_type/$resource_name not found"
    return 1
  fi

  # Get the desired replica count
  local desired_replicas=$(oc get $resource_type $resource_name -o jsonpath='{.spec.replicas}')
  if [[ "$desired_replicas" == "0" ]]; then
    log_success "$resource has scaled down to 0 replicas."
    return 0
  fi

  # Use cluster health monitoring if enabled via environment variable
  if [[ "${CLUSTER_HEALTH_MONITORING:-YES}" == "YES" ]]; then
    log_debug "🔄 Using centralized cluster health monitoring for $resource deployment..."

    # Create a wrapper function for the handle_pods_in_resource logic
    eval "
    handle_pods_wrapper() {
      handle_pods_in_resource \"$resource_type/$resource_name\" \"$DEPLOY_NAMESPACE\" \"check_pod_logs\" \"$error_search_string\" \"$error_handler\" \"$max_retries\" \"$wait_time\"
      return \$?
    }
    "

    # Calculate timeout in seconds (max_retries * wait_time)
    local timeout_seconds=$((max_retries * wait_time))

    # Use centralized cluster health monitoring with wrapper function
    wait_with_cluster_monitoring "$resource_type" "$resource_name" "handle_pods_wrapper" "$DEPLOY_NAMESPACE" "$timeout_seconds"
    local result=$?

    if [[ $result -eq 0 ]]; then
      log_success "All pods in $resource are ready and error-free."
    else
      log_error "Errors detected in pods for $resource or timeout occurred."
    fi

    return $result
  else
    log_debug "🔄 Using traditional waiting for $resource (CLUSTER_HEALTH_MONITORING=${CLUSTER_HEALTH_MONITORING:-NO})..."
    # Use traditional waiting without cluster monitoring
    if ! handle_pods_in_resource "$resource_type/$resource_name" "$DEPLOY_NAMESPACE" "check_pod_logs" "$error_search_string" "$error_handler" $max_retries $wait_time; then
      log_error "Errors detected in pods for $resource. Exiting..."
      return 1
    fi

    log_success "All pods in $resource are ready and error-free."
    return 0
  fi
}

check_timestamp() {
  IMAGE_REBUILD_TIME_LIMIT=${IMAGE_REBUILD_TIME_LIMIT:-86400} # Default to 24 hours
  local file_to_test=${1:-/var/www/html/index.php}
  local default_rerun_block_seconds=0 # Default to never blocking reruns
  local rerun_block_seconds=${IMAGE_REBUILD_TIME_LIMIT:-$default_rerun_block_seconds}

  log_info "Checking last time maintenance script was run..."

  # Check if the environment variable is set and valid
  if ! [[ "$rerun_block_seconds" =~ ^[0-9]+$ ]]; then
    log_warn "Invalid IMAGE_REBUILD_TIME_LIMIT value ($IMAGE_REBUILD_TIME_LIMIT). Using default value."
    rerun_block_seconds=$default_rerun_block_seconds
  fi

  # If the value is 0, do not enforce the time limit
  if [ "$rerun_block_seconds" -eq 0 ]; then
    log_info "IMAGE_REBUILD_TIME_LIMIT is set to 0. Time limit is not enforced."
    return 0
  fi

  local rerun_minutes=$((rerun_block_seconds / 60))
  local rerun_hours=$((rerun_minutes / 60))
  local last_modified_minutes=$(( ($(date +%s) - $(stat -c %Y $file_to_test)) / 60 ))

  log_debug "Last modified time: $last_modified_minutes minutes ago"
  log_debug "Rerun block time: $rerun_hours hours"
  log_debug "Current time: $(date +%Y-%m-%dT%H:%M:%S)"
  log_debug "Current time (epoch): $(date +%s)"
  log_debug "Last modified time (epoch): $(stat -c %Y $file_to_test)"
  log_debug "Difference in hours: $(( ($(date +%s) - $(stat -c %Y $file_to_test)) / 3600 )) hours"

  # Check if the script has been run within the past hour
  if [ -f "$file_to_test" ]; then
    if [ "$last_modified_minutes" -lt "$rerun_minutes" ]; then
      log_info "The script has been run within the past $rerun_hours hours."
      return 1
    else
      log_info "The script has not been run within the past $rerun_hours hours."
      return 0
    fi
  else
    log_warn "No file found to test last run time ($file_to_test)."
    return 0
  fi
}

# =============================================================================
# LOGGING AND ERROR HANDLING FUNCTIONS
# =============================================================================

# Function to log debug messages only when DEBUG_LEVEL is set to DEBUG
log_debug() {
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]] || [[ "${DEBUG_LEVEL}" == "TRACE" ]]; then
    echo "🔍 Debug: $*" >&2
  fi
}

# Function to log trace messages (ultra-verbose, command-level detail)
log_trace() {
  if [[ "${DEBUG_LEVEL}" == "TRACE" ]]; then
    echo "🔬 Trace: $*" >&2
  fi
}

# Function to log info messages (always shown)
log_info() {
  echo "ℹ️  $*" >&2
}

# Function to log warning messages (always shown)
log_warn() {
  echo "⚠️  $*" >&2
}

# Function to log error messages (always shown)
log_error() {
  echo "❌ $*" >&2
}

# Function to log success messages (always shown)
log_success() {
  echo "✅ $*"
}

# Function to check logs for a single pod
check_pod_logs() {
  local pod=$1
  local namespace=$2
  local error_search_strings=${3:-"error"}
  local error_handler=${4:-delete_pod}
  local log_file="/tmp/logs/check-pod-logs.log"
  local tail_lines=${5:-100}  # Only check recent logs to avoid startup noise

  # Split the error_search_strings into an array
  IFS=',' read -r -a error_strings <<< "$error_search_strings"

  # Check for malformed variables
  if [[ -z "$pod" || -z "$namespace" ]]; then
    log_error "ERROR: pod or namespace is empty!"
    return 1
  fi

  # Get the list of containers in the pod
  CONTAINERS=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}')
  IFS=' ' read -r -a container_array <<< "$CONTAINERS"

  for container in "${container_array[@]}"; do
    LOGS=$(oc logs "$pod" -n "$namespace" -c "$container" --tail="$tail_lines")

    for error_search_string in "${error_strings[@]}"; do
      if echo "$LOGS" | grep -q "$error_search_string"; then
        if echo "$LOGS" | grep -q "Success"; then
          log_info "Connection was lost but reestablished. No need to restart the pod."
          continue
        else
          log_warn "Error found in pod logs: $error_search_string"
          $error_handler $pod
          return 1  # Return failure if an error was found and handled
        fi
      fi
    done
  done

  log_success "No errors found in pod: $pod"
  return 0  # Return success if no errors were found
}

log_error_to_file() {
  local pod=$1
  local container=$2
  local error_line=$3
  local log_file=$4

  echo "Pod: $pod, Container: $container, Error: $error_line" >> $log_file
}

# Function to check logs for all pods in a deployment
check_deployment_logs() {
  eval "declare -A deployments="${1#*=}
  local max_retries=15
  local retry_count=0
  local wait_time=60

  for deployment in "${!deployments[@]}"; do
    local error_search_strings=${deployments[$deployment]:-"error"}
    local error_handler=${3:-delete_pod}
    local total_errors=0

    log_info "Checking logs: $deployment"

    while true; do
      local errors_detected=0

      # Get the list of pods in the deployment
      PODS=$(oc get pods -l $deployment -o jsonpath='{.items[*].metadata.name}')

      # Check if PODS is empty
      if [ -z "$PODS" ]; then
        log_warn "No pods found for deployment: $deployment"
        break
      fi

      # Convert PODS to an array
      IFS=' ' read -r -a pod_array <<< "$PODS"
      # Get number of pods in the array
      total_pods=$(echo $PODS | wc -w)

      for pod in "${pod_array[@]}"; do
        log_info "Processing pod logs: $pod"

        if ! check_pod_logs "$pod" "$DEPLOY_NAMESPACE" "$error_search_strings" "$error_handler"; then
          errors_detected=$((errors_detected + 1))
          total_errors=$((total_errors + 1))

          # Wait for the pod to be fully restarted and stabilized
          log_info "Waiting for pod $pod to restart and stabilize..."
          sleep $wait_time
          oc wait --for=condition=Ready pod/$pod --timeout=300s
          break
        fi
      done

      if [ $errors_detected -eq 0 ]; then
        log_success "✔️ OK"
        break
      else
        log_error "Errors found: $total_errors."
        retry_count=$((retry_count + 1))
        if [ $retry_count -ge $max_retries ]; then
          log_error "Max retries reached. Exiting..."
          return 1
        fi
        log_info "Waiting for pods to restart and stabilize..."
        sleep $wait_time
      fi
    done

    if [ $total_errors -ne 0 ]; then
      log_error "Errors detected: $total_errors"
    fi
  done

  return 0
}

# Enhanced logging function for structured events
log_critical_event() {
  local event_type="$1"
  local message="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local severity="${4:-warning}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')

  # Use severity-appropriate label for log aggregation
  local label="EVENT"
  case "$severity" in
    "error"|"failure") label="CRITICAL_EVENT" ;;
    "warning")         label="WARNING_EVENT" ;;
    "healing"|"repair") label="HEALING_EVENT" ;;
    "success")         label="INFO_EVENT" ;;
    *)                 label="INFO_EVENT" ;;
  esac

  # Log to stdout with structured format for OpenShift log aggregation
  echo "${label}|${timestamp}|${namespace}|${event_type}|${message}"

  # Also log to OpenShift events for visibility in cluster
  if command -v oc >/dev/null 2>&1; then
    oc create event --type=Warning --reason="$event_type" --message="$message" --reporting-instance="check-pod-logs" --reporting-component="galera-monitor" 2>/dev/null || true
  fi
}

# Function to send notifications matching GitHub workflow style
send_notification() {
  local event_type="$1"
  local title="$2"
  local message="$3"
  local severity="${4:-warning}"  # warning, error, success
  local namespace="${5:-$DEPLOY_NAMESPACE}"

  # Determine emoji based on severity (matching GitHub workflow style)
  local emoji=""
  case "$severity" in
    "success")
      emoji=":white_check_mark:"
      ;;
    "error"|"failure")
      emoji=":boom:"
      ;;
    "warning")
      emoji=":warning:"
      ;;
    "healing"|"repair")
      emoji=":wrench:"
      ;;
    "info")
      emoji=":information_source:"
      ;;
    *)
      emoji=":grey_question:"
      ;;
  esac

  # Only send webhook for critical events (errors, failures, healing attempts)
  if [[ "$severity" =~ ^(error|failure|warning|healing)$ ]] && [[ -n "$ROCKET_CHAT_WEBHOOK" ]]; then
    local webhook_payload=$(cat << EOF
{
  "emoji": "$emoji",
  "text": "**${title}** in \`${namespace}\`",
  "attachments": [{
    "title": "Galera Cluster Monitor Alert",
    "color": "${severity}",
    "fields": [{
      "title": "Event Type",
      "value": "$event_type",
      "short": true
    },{
      "title": "Namespace",
      "value": "$namespace",
      "short": true
    },{
      "title": "Details",
      "value": "$message"
    },{
      "title": "Timestamp",
      "value": "$(date '+%Y-%m-%d %H:%M:%S UTC')",
      "short": true
    }]
  }]
}
EOF
    )

    # Send webhook notification (non-blocking)
    curl -s -X POST "$ROCKET_CHAT_WEBHOOK" \
      -H 'Content-Type: application/json' \
      -d "$webhook_payload" > /dev/null 2>&1 || true
  fi

  # Log events for aggregation (only for actionable severities)
  if [[ "$severity" =~ ^(error|failure|warning|healing)$ ]]; then
    log_critical_event "$event_type" "$message" "$namespace" "$severity"
  fi
}

# Function to check logs for errors and restart if needed
check_and_restart_pod() {
  local selector="$1"
  local error_patterns="$2"

  log_info "Checking pods with selector: $selector"

  # Get all running pods matching the selector
  local pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$pods" ]]; then
    log_warn "No running pods found for selector: $selector"
    return
  fi

  # Convert comma-separated patterns to array
  IFS=',' read -ra patterns <<< "$error_patterns"

  local pods_restarted=0

  for pod in $pods; do
    log_info "Checking pod: $pod"

    # Get recent logs (last 50 lines to avoid overwhelming output)
    local logs=$(oc logs "$pod" --tail=50 2>/dev/null)

    if [[ -z "$logs" ]]; then
      log_warn "No logs available for pod: $pod"
      continue
    fi

    local errors_found=false
    local found_pattern=""

    # Check for each error pattern
    for pattern in "${patterns[@]}"; do
      pattern=$(echo "$pattern" | xargs)  # Trim whitespace
      if echo "$logs" | grep -q "$pattern"; then
        log_error "Error pattern '$pattern' found in pod $pod"
        errors_found=true
        found_pattern="$pattern"
        break
      fi
    done

    if [[ "$errors_found" == "true" ]]; then
      log_warn "🔄 Restarting pod $pod due to error pattern: $found_pattern"
      oc delete pod "$pod" --grace-period=0 --force 2>/dev/null || true
      pods_restarted=$((pods_restarted + 1))

      # Send notification for individual pod restart
      send_notification "POD_RESTART" "Pod Restarted Due to Errors" "Pod '$pod' restarted due to error pattern: $found_pattern" "warning" "$DEPLOY_NAMESPACE"

      # Wait for pod to be recreated
      sleep 30
    else
      log_success "    ✅ Pod $pod is healthy (no error patterns found)"
    fi
  done

  # Send summary notification if multiple pods were restarted
  if [[ $pods_restarted -gt 1 ]]; then
    send_notification "MULTIPLE_POD_RESTARTS" "Multiple Pods Restarted" "$pods_restarted pods with selector '$selector' were restarted due to errors" "warning" "$DEPLOY_NAMESPACE"
  fi
}

# =============================================================================
# MAINTENANCE MODE AND ROUTE MANAGEMENT FUNCTIONS
# =============================================================================

# Helper function to get the standard route name for any environment
get_standard_route_name() {
  local namespace="${1:-$DEPLOY_NAMESPACE}"
  echo "${APP:-moodle}-${WEB_DEPLOYMENT_NAME:-web}"
}

# Function to verify that specific routes are pointing to the correct service
verify_route_target() {
  local expected_service="$1"
  local route_names="$2"  # Comma-separated list of route names to check
  local timeout="${3:-120}"
  local check_interval="${4:-10}"
  local elapsed=0

  # Convert comma-separated route names to array
  IFS=',' read -ra routes_to_check <<< "$route_names"

  log_info "🔍 Verifying specific routes are pointing to service: $expected_service"
  log_info "    Routes to verify: ${routes_to_check[*]}"

  while [[ $elapsed -lt $timeout ]]; do
    local routes_status="✅"
    local routes_info=""

    # Check only the specified routes
    for route_name in "${routes_to_check[@]}"; do
      # Trim whitespace from route name
      route_name=$(echo "$route_name" | xargs)

      # Check if route exists and get its target service
      local current_target=$(oc get route "$route_name" -o jsonpath='{.spec.to.name}' 2>/dev/null)

      if [[ -z "$current_target" ]]; then
        routes_info+="  ⚠️ Route '$route_name' → NOT FOUND\n"
        routes_status="❌"
      elif [[ "$current_target" == "$expected_service" ]]; then
        routes_info+="  ✅ Route '$route_name' → $current_target\n"
      else
        routes_info+="  ❌ Route '$route_name' → $current_target (expected: $expected_service)\n"
        routes_status="❌"
      fi
    done

    log_debug -e "$routes_info"

    if [[ "$routes_status" == "✅" ]]; then
      log_success "All specified routes are correctly pointing to '$expected_service'"
      return 0
    fi

    log_info "⏳ Waiting for route changes to propagate... ($elapsed/$timeout seconds)"
    sleep $check_interval
    elapsed=$((elapsed + check_interval))
  done

  log_error "Timeout: Specified routes are not pointing to '$expected_service' after $timeout seconds"
  return 1
}

# Function to verify the application is responding correctly
verify_application_response() {
  local timeout="${1:-60}"
  local check_interval="${2:-10}"
  local elapsed=0

  log_info "Verifying application is responding correctly..."

  # Get the route URL
  local route_url=$(oc get route -o jsonpath='{.items[0].spec.host}' 2>/dev/null)
  if [[ -z "$route_url" ]]; then
    log_warn "Could not determine route URL, skipping response verification"
    return 0
  fi

  log_info "🌐 Testing application response at: https://$route_url"

  while [[ $elapsed -lt $timeout ]]; do
    # Test the application response, following redirects
    local response_code=$(curl -s -o /dev/null -w "%{http_code}" -L -k "https://$route_url" --max-time 30 2>/dev/null || echo "000")

    # Also get the final URL after redirects for debugging
    local final_url=$(curl -s -o /dev/null -w "%{url_effective}" -L -k "https://$route_url" --max-time 30 2>/dev/null || echo "unknown")

    # Accept various success responses
    if [[ "$response_code" =~ ^(200|201|202)$ ]]; then
      log_success "✅ Application is responding correctly (HTTP $response_code)"
      if [[ "$final_url" != "https://$route_url" ]]; then
        log_info "🔗 Final URL after redirects: $final_url"
      fi
      return 0
    elif [[ "$response_code" == "000" ]]; then
      log_info "⏳ Connection failed, retrying... ($elapsed/$timeout seconds)"
    elif [[ "$response_code" =~ ^(3[0-9][0-9])$ ]]; then
      log_info "⏳ Application returned redirect HTTP $response_code (following redirects), retrying... ($elapsed/$timeout seconds)"
    else
      log_info "⏳ Application returned HTTP $response_code, retrying... ($elapsed/$timeout seconds)"
    fi

    sleep $check_interval
    elapsed=$((elapsed + check_interval))
  done

  log_error "Application is not responding correctly after $timeout seconds"
  return 1
}

# Generic function to apply JSON patches to Kubernetes resources
apply_resource_patch() {
  local resource_type="$1"    # e.g., "statefulset", "deployment", "route"
  local resource_name="$2"    # e.g., "redis-node"
  local patch_operations="$3" # JSON array of patch operations as string
  local namespace="${4:-$DEPLOY_NAMESPACE}"
  local description="${5:-Applying patch}"

  log_debug "🔧 $description for $resource_type/$resource_name..."

  # Check if the resource exists
  if ! oc get "$resource_type" "$resource_name" -n "$namespace" &> /dev/null; then
    log_warn "$resource_type $resource_name does not exist. Skipping patch."
    return 1
  fi

  # Create temporary patch file
  local patch_file="/tmp/patch-${resource_type}-${resource_name}-$$.json"
  echo "$patch_operations" > "$patch_file"

  # Debug: Show what we're about to patch
  log_debug "Patch file contents: $(cat "$patch_file")"

  # Apply the patch
  if oc patch "$resource_type" "$resource_name" -n "$namespace" --type=json --patch-file="$patch_file"; then
    log_success "Successfully applied patch to $resource_type/$resource_name"
    rm -f "$patch_file"
    return 0
  else
    log_warn "Warning: Failed to apply patch to $resource_type/$resource_name"
    rm -f "$patch_file"
    return 1
  fi
}

# Generic function to verify patch results using JSONPath
verify_patch_result() {
  local resource_type="$1"
  local resource_name="$2"
  local jsonpath_checks="$3"  # Array of "jsonpath:expected_value" pairs
  local namespace="${4:-$DEPLOY_NAMESPACE}"

  log_info "Verifying patch results for $resource_type/$resource_name..."

  # Parse jsonpath_checks (format: "path1:value1,path2:value2")
  IFS=',' read -ra checks <<< "$jsonpath_checks"

  local all_verified=true
  for check in "${checks[@]}"; do
    IFS=':' read -ra parts <<< "$check"
    local jsonpath="${parts[0]}"
    local expected="${parts[1]}"

    local actual
    actual=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath="$jsonpath" 2>/dev/null)

    if [[ "$actual" == "$expected" ]]; then
      log_success "Verified: $jsonpath = $expected"
    else
      log_warn "Failed verification: $jsonpath = '$actual' (expected '$expected')"
      all_verified=false
    fi
  done

  [[ "$all_verified" == "true" ]]
}

# Fast route patching without immediate verification (for batch operations)
patch_route_fast() {
  local route_name="$1"
  local target_service="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  log_info "🔄 Patching route [fast] $route_name to point to $target_service..."

  # Show current route target
  if oc get route "$route_name" -n "$namespace" &> /dev/null; then
    local current_target
    current_target=$(oc get route "$route_name" -n "$namespace" -o jsonpath='{.spec.to.name}' 2>/dev/null)
    log_info "  Current: $route_name → $current_target"

    # Early exit if already pointing to target service
    if [[ "$current_target" == "$target_service" ]]; then
      log_info "  Route already pointing to $target_service, skipping patch"
      return 0
    fi
  fi

  # Verify target service exists before patching
  if ! oc get service "$target_service" -n "$namespace" &> /dev/null; then
    log_error "Target service '$target_service' does not exist in namespace '$namespace'"
    log_debug "Available services:"
    if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
      oc get services -n "$namespace" -o name | head -10
    fi
    return 1
  fi

  # Create patch operation
  local patch_ops='[{"op": "replace", "path": "/spec/to/name", "value": "'"$target_service"'"}]'

  log_debug " Route patch details:"
  log_debug "  Route: $route_name"
  log_debug "  Namespace: $namespace"
  log_debug "  Target service: $target_service"
  log_debug "  Patch operations: $patch_ops"

  # Apply the patch using generic function
  if apply_resource_patch "route" "$route_name" "$patch_ops" "$namespace" "Updating route target"; then
    log_success "Patch applied to route $route_name"

    # Verify the patch actually took effect
    sleep 2  # Brief wait for patch to apply
    local new_target
    new_target=$(oc get route "$route_name" -n "$namespace" -o jsonpath='{.spec.to.name}' 2>/dev/null)
    if [[ "$new_target" == "$target_service" ]]; then
      log_success "Route patch verified: $route_name → $new_target"
    else
      log_error "Route patch failed verification: $route_name → $new_target (expected: $target_service)"
      return 1
    fi

    return 0
  else
    log_error "Failed to apply patch to route $route_name"
    return 1
  fi
}

# Updated patch_route function using generic approach with integrated verification
patch_route() {
  local route_name="$1"
  local target_service="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local verify_timeout="${4:-60}"  # Verification timeout in seconds

  log_info "Patching route $route_name to point to $target_service..."

  # Show current route target
  if oc get route "$route_name" -n "$namespace" &> /dev/null; then
    local current_target
    current_target=$(oc get route "$route_name" -n "$namespace" -o jsonpath='{.spec.to.name}' 2>/dev/null)
    log_info "Current route: $current_target"
  fi

  # Create patch operation
  local patch_ops='[{"op": "replace", "path": "/spec/to/name", "value": "'"$target_service"'"}]'

  # Apply the patch using generic function
  if apply_resource_patch "route" "$route_name" "$patch_ops" "$namespace" "Updating route target"; then
    # Verify the route change took effect using the enhanced verification function
    log_info "Verifying route patch was successful..."
    if verify_route_target "$target_service" "$route_name" "$verify_timeout" 5; then
      log_success "Route $route_name successfully updated and verified to point to $target_service"
      return 0
    else
      log_error "Route patch failed verification - route $route_name is not pointing to $target_service"
      return 1
    fi
  else
    log_error "Failed to apply patch to route $route_name"
    return 1
  fi
}

# Function to patch all relevant routes for the environment (optimized for parallel processing)
patch_all_routes() {
  local target_service="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local verify_timeout="${3:-60}"
  local patch_success=true
  local routes_to_patch=()
  local routes_for_verification=""

  # Determine which routes to patch
  local standard_route=$(get_standard_route_name "$namespace")
  routes_to_patch+=("$standard_route")
  routes_for_verification="$standard_route"

  # In production, also patch the custom route
  if [[ "$namespace" == "950003-prod" ]]; then
    routes_to_patch+=("moodle-custom")
    routes_for_verification="$routes_for_verification,moodle-custom"
  fi

  log_info "🚀 Optimized route patching for $namespace environment"
  log_debug "📋 Routes to patch: ${routes_to_patch[*]}"

  # Phase 1: Apply all patches quickly without waiting for verification
  log_info ""
  log_info "🔄 Phase 1: Applying all route patches..."
  for route in "${routes_to_patch[@]}"; do
    if ! patch_route_fast "$route" "$target_service" "$namespace"; then
      log_error "Failed to patch route: $route"
      patch_success=false
    fi
  done

  if [[ "$patch_success" != "true" ]]; then
    log_error "Some route patches failed - aborting"
    return 1
  fi

  # Phase 2: Wait a moment for patches to propagate, then verify all routes together
  log_info ""
  log_info "⏳ Phase 2: Allowing patches to propagate (10 seconds)..."
  sleep 10

  log_info "🔍 Phase 3: Verifying all routes together..."
  if verify_route_target "$target_service" "$routes_for_verification" "$verify_timeout" 5; then
    log_success "Successfully patched and verified all routes for $namespace environment"
    return 0
  else
    log_error "Route verification failed for some routes"
    return 1
  fi
}

# Function to deploy and enable maintenance mode
enable_maintenance_mode() {
  local service_name=$1
  local route_mode=${2:-"auto"}  # "auto" means use patch_all_routes, or specific route name
  local route_timeout="60s"

  log_info "Deploying maintenance mode for service: $service_name"

  # Scale to 1 replica
  scale_deployment "deployment" "$service_name" 1 1

  # Create / update route
  deploy_resource_from_template ./openshift/web-route-template.yml \
    "APP=$APP" \
    "WEB_DEPLOYMENT_NAME=$WEB_DEPLOYMENT_NAME" \
    "APP_HOST_URL=$APP_HOST_URL" \
    "DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE" \

  # Redirect traffic to maintenance service
  if [[ "$route_mode" == "auto" ]]; then
    log_info "Redirecting all relevant routes to maintenance service..."
    patch_all_routes "$service_name"
  else
    log_info "Redirecting specific route $route_mode to $service_name..."
    patch_route "$route_mode" "$service_name"
  fi
}

# Function to disable maintenance mode
disable_maintenance_mode() {
  local target_service_name="${1:-web}"  # Service to redirect traffic to
  local maintenance_service_name="${2:-maintenance-message}"  # Maintenance service to scale down
  local route_mode="${3:-auto}"  # Route handling mode

  log_info "Disabling $maintenance_service_name and redirecting to $target_service_name..."

  # Redirect traffic back to application
  if [[ "$route_mode" == "auto" ]]; then
    log_info "Redirecting all relevant routes back to application service: $target_service_name"
    patch_all_routes "$target_service_name"
  else
    log_info "Redirecting specific route $route_mode to $target_service_name..."
    patch_route "$route_mode" "$target_service_name"
  fi

  log_success "Route redirection completed - traffic now directed to $target_service_name"
  log_info "Note: Maintenance service scaling should be handled by caller after verification"
}

# =============================================================================
# SECRET MANAGEMENT FUNCTIONS
# =============================================================================

# Function to validate and get current secret values
get_secret_value() {
  local secret_name="$1"
  local key="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  if oc get secret "$secret_name" -n "$namespace" &> /dev/null; then
    # Get the base64 encoded value and decode it
    oc get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Function to validate if secret values match expected values
validate_secret_values() {
  local secret_name="$1"
  local expected_values="$2"  # Format: "key1=value1,key2=value2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  if ! oc get secret "$secret_name" -n "$namespace" &> /dev/null; then
    log_error "Secret '$secret_name' does not exist"
    return 1
  fi

  log_info "Validating secret '$secret_name' values..."

  # Parse expected values
  IFS=',' read -ra expected_pairs <<< "$expected_values"
  local validation_failed=false

  for pair in "${expected_pairs[@]}"; do
    if [[ "$pair" == *"="* ]]; then
      local key="${pair%%=*}"
      local expected_value="${pair#*=}"
      local current_value=$(get_secret_value "$secret_name" "$key" "$namespace")

      if [[ "$current_value" != "$expected_value" ]]; then
        log_error "Key '$key': value mismatch"
        validation_failed=true
      else
        log_success "Key '$key': value matches"
      fi
    fi
  done

  if [[ "$validation_failed" == "true" ]]; then
    return 1
  else
    log_success "All secret values validated successfully"
    return 0
  fi
}

# Function to create or update a secret
create_or_update_secret() {
  local secret_name="$1"
  local secret_data="$2"  # Format: "key1=value1,key2=value2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  log_info "Creating/updating secret '$secret_name'..."

  # Delete existing secret if it exists
  if oc get secret "$secret_name" -n "$namespace" &> /dev/null; then
    log_info "Deleting existing secret..."
    oc delete secret "$secret_name" -n "$namespace"
  fi

  # Parse secret data and build from-literal arguments array
  local from_literal_args=()
  IFS=',' read -ra data_pairs <<< "$secret_data"

  for pair in "${data_pairs[@]}"; do
    if [[ "$pair" == *"="* ]]; then
      local key="${pair%%=*}"
      local value="${pair#*=}"
      from_literal_args+=("--from-literal=${key}=${value}")
    fi
  done

  # Execute the command with proper argument handling
  if oc create secret generic "$secret_name" -n "$namespace" "${from_literal_args[@]}"; then
    log_success "Secret '$secret_name' created/updated successfully"
    return 0
  else
    log_error "Failed to create/update secret '$secret_name'"
    return 1
  fi
}

# Function to manage secrets with validation
manage_secret_with_validation() {
  local secret_name="$1"
  local secret_data="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local force_update="${4:-false}"

  log_info "Managing secret '$secret_name' with validation..."

  # If force_update is false, check if secret already exists and matches
  if [[ "$force_update" != "true" ]]; then
    if validate_secret_values "$secret_name" "$secret_data" "$namespace"; then
      log_success "Secret '$secret_name' already exists with correct values"
      return 0  # No changes needed
    fi
  fi

  # Create or update the secret
  if create_or_update_secret "$secret_name" "$secret_data" "$namespace"; then
    # Validate the created secret
    if validate_secret_values "$secret_name" "$secret_data" "$namespace"; then
      log_success "Secret '$secret_name' created and validated successfully"
      return 2  # Changes were made
    else
      log_error "Secret created but validation failed"
      return 1  # Error
    fi
  else
    log_error "Failed to create secret '$secret_name'"
    return 1  # Error
  fi
}

# Function to create or update a ConfigMap
create_or_update_configmap() {
  local configmap_name=$1
  shift
  local file_paths=("$@")

  delete_resource_if_exists configmap $configmap_name
  log_info "Creating ConfigMap: $configmap_name"

  # Construct the oc create configmap command with multiple --from-file flags
  local create_cmd="oc create configmap $configmap_name"
  for file_path in "${file_paths[@]}"; do
    create_cmd+=" --from-file=$file_path"
  done

  # Execute the command
  eval $create_cmd
}

# Generic function to restart any Kubernetes resource (deployment, statefulset, daemonset)
restart_resource() {
  local resource_type="$1"   # e.g., "deployment", "statefulset", "daemonset"
  local resource_name="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local timeout="${4:-300s}"
  local reason="${5:-configuration changes}"

  log_info "🔄 Restarting $resource_type '$resource_name' to pick up $reason..."

  # Standardize resource type names
  case "$resource_type" in
    "sts") resource_type="statefulset" ;;
    "deploy") resource_type="deployment" ;;
    "ds") resource_type="daemonset" ;;
  esac

  # Check if resource exists
  if ! oc get "$resource_type" "$resource_name" -n "$namespace" &> /dev/null; then
    log_error "$resource_type '$resource_name' not found in namespace '$namespace'"
    return 1
  fi

  # Initiate rollout restart
  if oc rollout restart "$resource_type/$resource_name" -n "$namespace"; then
    log_info "$resource_type '$resource_name' restart initiated"

    # Wait for the rollout to complete
    if oc rollout status "$resource_type/$resource_name" -n "$namespace" --timeout="$timeout"; then
      log_success "$resource_type '$resource_name' restart completed successfully"
      return 0
    else
      log_error "$resource_type '$resource_name' restart timed out or failed after $timeout"
      return 1
    fi
  else
    log_error "Failed to restart $resource_type '$resource_name'"
    return 1
  fi
}

# Utility function to ensure StatefulSet partition is set correctly for updates
# Kubernetes won't restart pods if partition >= replica count
ensure_statefulset_partition() {
  local statefulset_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local target_partition="${3:-0}"  # Default to 0 for full updates

  local current_partition
  current_partition=$(oc get statefulset/"$statefulset_name" -n "$namespace" -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}' 2>/dev/null)

  # If partition not set or null, it defaults to 0 (all pods update)
  if [[ -z "$current_partition" || "$current_partition" == "null" ]]; then
    log_debug "Partition not set for $statefulset_name - assuming 0"
    return 0
  fi

  # If already at target, nothing to do
  if [[ "$current_partition" -eq "$target_partition" ]]; then
    log_debug "Partition already at $target_partition for $statefulset_name"
    return 0
  fi

  # Reset partition to target value
  log_warn "⚠️  StatefulSet partition is $current_partition - resetting to $target_partition to enable pod updates"
  if oc patch statefulset/"$statefulset_name" -n "$namespace" --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/updateStrategy/rollingUpdate/partition\",\"value\":$target_partition}]"; then
    log_success "✅ Partition reset to $target_partition - all pods can now be updated"
    return 0
  else
    log_error "❌ Failed to reset partition for $statefulset_name"
    return 1
  fi
}

# Specialized function to restart StatefulSets with Galera-specific safety checks
restart_statefulset() {
  local statefulset_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local timeout="${3:-600s}"
  local verify_galera="${4:-auto}"  # "auto", "true", "false"
  local expected_replicas="${5:-}"  # Optional: for Galera health verification

  log_info "🔄 Restarting StatefulSet '$statefulset_name' with safety checks..."

  # Safety check: Verify updateStrategy is RollingUpdate
  local update_strategy
  update_strategy=$(oc get statefulset/"$statefulset_name" -n "$namespace" -o jsonpath='{.spec.updateStrategy.type}' 2>/dev/null)

  if [[ "$update_strategy" != "RollingUpdate" ]]; then
    log_error "❌ StatefulSet updateStrategy is '$update_strategy' (expected: RollingUpdate)"
    log_error "   Restart may not be safe for StatefulSet. Aborting."
    log_error "   Manual intervention recommended: verify configuration before restarting."
    return 1
  fi

  log_info "✅ Verified updateStrategy: RollingUpdate (safe for StatefulSet restart)"

  # Ensure partition is set to 0 - pods won't restart if partition >= replica count
  if ! ensure_statefulset_partition "$statefulset_name" "$namespace" 0; then
    log_error "Failed to ensure correct partition setting - aborting restart"
    return 1
  fi

  # Auto-detect if this is a Galera StatefulSet
  local is_galera="false"
  if [[ "$verify_galera" == "auto" ]]; then
    if [[ "$statefulset_name" == *"galera"* || "$statefulset_name" == *"mariadb"* ]]; then
      is_galera="true"
      log_info "🔍 Detected Galera StatefulSet - will verify cluster health after restart"
    fi
  elif [[ "$verify_galera" == "true" ]]; then
    is_galera="true"
  fi

  # Perform the restart using generic function
  if restart_resource "statefulset" "$statefulset_name" "$namespace" "$timeout" "configuration changes"; then
    # Galera-specific: Re-verify cluster health after restart
    if [[ "$is_galera" == "true" ]]; then
      log_info "🔍 Re-verifying Galera cluster health after restart..."

      # If expected_replicas not provided, get it from the StatefulSet
      if [[ -z "$expected_replicas" ]]; then
        expected_replicas=$(oc get statefulset/"$statefulset_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
      fi

      # Use wait_for_galera_sync if available
      if type -t wait_for_galera_sync >/dev/null 2>&1; then
        if wait_for_galera_sync "$statefulset_name" "" "" "$expected_replicas"; then
          log_success "✅ Galera cluster healthy after restart"

          # Additional split-brain check if function is available
          if type -t check_galera_cluster_health >/dev/null 2>&1; then
            check_galera_cluster_health "app.kubernetes.io/name=$statefulset_name" "$namespace" "$expected_replicas"
            local galera_health=$?
            if [[ $galera_health -eq 2 ]]; then
              log_error "🚨 SPLIT-BRAIN DETECTED after restart!"
              return 1
            elif [[ $galera_health -eq 1 ]]; then
              log_warn "⚠️ Some Galera pods unhealthy after restart"
              return 1
            fi
          fi

          return 0
        else
          log_error "⚠️ Galera cluster health check failed after restart"
          return 1
        fi
      else
        log_warn "wait_for_galera_sync not available - skipping Galera health verification"
        return 0
      fi
    else
      return 0
    fi
  else
    return 1
  fi
}

# Backward compatibility wrapper: restart deployments when secrets change
restart_deployment() {
  local deployment_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  restart_resource "deployment" "$deployment_name" "$namespace" "300s" "secret changes"
}

# =============================================================================
# MONITORING AND STATUS FUNCTIONS
# =============================================================================

# Function to handle job-specific logic
handle_job_status() {
  local job_name=$1
  local max_retries=$2
  local retry_count=$3
  local wait_time=$4

  # Enhanced monitoring variables for jobs
  local cluster_monitoring_enabled="${CLUSTER_HEALTH_MONITORING:-YES}"
  local last_health_check=0
  local health_check_interval=300  # Check every 5 minutes
  local consecutive_storage_failures=0
  local max_storage_failures=3
  local original_max_retries=$max_retries
  local storage_extension_applied=false

  log_debug "🔄 Starting job monitoring with cluster health enabled: $cluster_monitoring_enabled"

  while true; do
    # Check if the job has failed
    local job_failed=$(oc get jobs $job_name -o 'jsonpath={..status.failed}')
    if [[ $job_failed -gt 0 ]]; then
      log_error "Job $job_name has failed. Retrieving logs..."
      local pod_name=$(oc get pods --selector=job-name=$job_name -o jsonpath='{.items[0].metadata.name}')
      if [[ -n "$pod_name" ]]; then
        local error_log_text=$(oc logs $pod_name 2>/dev/null || echo "No logs available")
        log_error "Error log:"
        log_error "$error_log_text"
      else
        log_warn "No pod found for job $job_name to retrieve logs"
      fi
      return 1
    fi

    # Check if the job has succeeded
    local job_succeeded=$(oc get jobs $job_name -o 'jsonpath={..status.succeeded}')
    if [[ $job_succeeded -gt 0 ]]; then
      log_success "Job $job_name has completed successfully."
      return 0
    fi

    # Perform cluster health check if enabled and enough time has passed
    if [[ "$cluster_monitoring_enabled" == "YES" ]]; then
      local current_time=$((retry_count * wait_time))
      if [[ $((current_time - last_health_check)) -ge $health_check_interval ]]; then
        log_debug "Performing cluster health check for job $job_name..."

        # Get pod associated with the job for health checking
        local pod_name=$(oc get pods --selector=job-name=$job_name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

        local health_status
        if [[ -n "$pod_name" ]]; then
          health_status=$(check_cluster_health "Pod" "$pod_name" "$DEPLOY_NAMESPACE")
        else
          health_status=$(check_cluster_health "Job" "$job_name" "$DEPLOY_NAMESPACE")
        fi
        local health_exit_code=$?

        case "$health_status" in
          "STORAGE_CRITICAL")
            consecutive_storage_failures=$((consecutive_storage_failures + 1))
            log_warn "Storage issues detected for job $job_name (attempt $consecutive_storage_failures/$max_storage_failures)"

            if [[ $consecutive_storage_failures -ge $max_storage_failures && "$storage_extension_applied" == "false" ]]; then
              # Extend max_retries for persistent storage issues
              local extension_retries=$((15 * 60 / wait_time))  # Add 15 minutes worth of retries
              max_retries=$((max_retries + extension_retries))
              storage_extension_applied=true
              log_warn "🕒 Extending job timeout due to persistent storage issues..."
              log_info "   Original timeout: $((original_max_retries * wait_time))s"
              log_info "   Extended timeout: $((max_retries * wait_time))s"
              log_info "🔍 Showing cluster events for troubleshooting..."
              show_cluster_events "Job" "$job_name" "$DEPLOY_NAMESPACE"

              # Also show pod-specific events if available
              if [[ -n "$pod_name" ]]; then
                log_info "🔍 Showing pod events for $pod_name..."
                show_cluster_events "Pod" "$pod_name" "$DEPLOY_NAMESPACE"
              fi
            fi
            ;;
          "NODE_CRITICAL"|"NETWORK_WARNING")
            log_warn "Cluster infrastructure issues detected for job $job_name"
            show_cluster_events "Job" "$job_name" "$DEPLOY_NAMESPACE"
            if [[ -n "$pod_name" ]]; then
              show_cluster_events "Pod" "$pod_name" "$DEPLOY_NAMESPACE"
            fi
            ;;
          "HEALTHY")
            consecutive_storage_failures=0
            log_success "Cluster health check: Normal for job $job_name"
            ;;
        esac

        last_health_check=$current_time
      fi
    fi

    # Retry logic
    if [[ $retry_count -ge $max_retries ]]; then
      if [[ "$storage_extension_applied" == "true" ]]; then
        log_error "Timeout waiting for job $job_name to complete (extended timeout due to storage issues). Exiting..."
        log_info "Consider checking cluster storage health or increasing PVC attachment timeout settings."
      else
        log_error "Timeout waiting for job $job_name to complete. Exiting..."
      fi

      # Show final cluster status for troubleshooting
      if [[ "$cluster_monitoring_enabled" == "YES" ]]; then
        log_info "Final cluster health check for troubleshooting..."
        local pod_name=$(oc get pods --selector=job-name=$job_name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$pod_name" ]]; then
          show_cluster_events "Pod" "$pod_name" "$DEPLOY_NAMESPACE"
        else
          show_cluster_events "Job" "$job_name" "$DEPLOY_NAMESPACE"
        fi
      fi

      return 1
    fi

    log_info "Waiting for job $job_name to complete... (Retry $retry_count/$max_retries)"
    sleep $wait_time
    retry_count=$((retry_count + 1))
  done
}

# Function to handle deployment-specific logic
handle_deployment_status() {
  local resource_name=$1
  local condition=$2
  local scale_direction=$3
  local max_retries=$4
  local retry_count=$5
  local wait_time=$6
  local resource_type=${7:-""}  # Optional resource type parameter

  while true; do
    # Get the list of pods for the resource
    local pods
    # If resource_type is provided, use full resource identifier
    if [[ -n "$resource_type" ]]; then
      pods=$(get_pods_for_resource "$resource_type/$resource_name" "$DEPLOY_NAMESPACE")
    else
      pods=$(get_pods_for_resource "$resource_name" "$DEPLOY_NAMESPACE")
    fi
    local status=$?

    if [[ $status -ne 0 ]]; then
      log_debug "Failed to retrieve pods for resource: $resource_name. Retrying..."
      retry_count=$((retry_count + 1))
      if [[ $retry_count -ge $max_retries ]]; then
        # Use debug for single-iteration calls to avoid log spam
        if [[ $max_retries -le 1 ]]; then
          log_debug "Single check timeout for condition '$condition' with resource: $resource_name"
        else
          log_error "Timeout waiting for condition '$condition' with resource: $resource_name. Exiting..."
        fi
        return 1
      fi
      sleep $wait_time
      continue
    fi

    if [[ $scale_direction == "up" ]]; then
      if [[ -z "$pods" ]]; then
        log_debug "No pods found for $resource_name. Retrying..."

        # Add debug info on first failure and every 10 retries
        if [[ $retry_count -eq 0 ]] || [[ $((retry_count % 10)) -eq 0 ]]; then
          log_debug "Debug: Investigating pod discovery issue..."
          debug_deployment_pods "$resource_name" "$DEPLOY_NAMESPACE"
        fi
      else
        local all_pods_ready=true
        local pods_status=""
        for pod in $pods; do
          local output=$(oc wait --for=condition=$condition pod/$pod --timeout=${wait_time}s 2>&1)
          if ! echo "$output" | grep -q "condition met"; then
            all_pods_ready=false
            pods_status+="$pod:not-$condition "
            break
          else
            pods_status+="$pod:$condition "
          fi
        done

        if $all_pods_ready; then
          log_success "All pods for $resource_name are in '$condition' condition."
          return 0
        else
          # Use debug for routine waiting, info only for first few attempts or periodic updates
          if [[ $retry_count -le 3 ]] || [[ $((retry_count % 10)) -eq 0 ]]; then
            log_debug "Waiting for $resource_name pods to be $condition: $pods_status"
          fi
        fi
      fi
    elif [[ $scale_direction == "down" ]]; then
      if [[ -z "$pods" ]]; then
        log_success "All pods for $resource_name have scaled down."
        return 0
      else
        log_debug "Pods still exist for $resource_name ($pods). Retrying..."
      fi
    fi

    # Retry logic
    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      # Use debug for single-iteration calls to avoid log spam
      if [[ $max_retries -le 1 ]]; then
        log_debug "Single check timeout for condition '$condition' with resource: $resource_name"
      else
        log_error "Timeout waiting for condition '$condition' with resource: $resource_name. Exiting..."
      fi
      return 1
    fi

    # Show progress less frequently to reduce log noise
    if [[ $max_retries -gt 1 ]]; then
      log_debug "Retrying... ($(((retry_count + 1) * wait_time))/$((max_retries * wait_time)))"
    fi
    sleep $wait_time
  done
}

# Function to handle pods in a resource
handle_pods_in_resource() {
  local resource="$1"
  local namespace="$2"
  local check_function="$3"
  local error_search_string="$4"
  local error_handler="$5"
  local max_retries="${6:-30}"
  local wait_time="${7:-30}"

  local retry_count=0

  while [[ $retry_count -lt $max_retries ]]; do
    # Get pods for the resource
    local pods=$(get_pods_for_resource "$resource" "$namespace")

    if [[ -z "$pods" ]]; then
      log_info "No pods found for $resource. Retrying..."
    else
      local all_pods_healthy=true
      for pod in $pods; do
        if ! $check_function "$pod" "$namespace" "$error_search_string" "$error_handler"; then
          all_pods_healthy=false
          log_warn "Pod $pod has errors. Waiting for restart..."
          break
        fi
      done

      if $all_pods_healthy; then
        log_success "All pods for $resource are healthy."
        return 0
      fi
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      log_error "Timeout: Pods for $resource still have issues after $((max_retries * wait_time)) seconds"
      return 1
    fi

    log_info "Retrying pod health check... ($retry_count/$max_retries)"
    sleep $wait_time
  done
}

# Function to create or update a Helm deployment
create_or_update_helm_deployment() {
  local helm_name=$1
  local helm_chart=$2
  local values_file=$3
  local upgrade_file=$4
  local additional_set_args="${5:-}"  # Optional: additional --set arguments

  if helm list -q | grep -q "^$helm_name$"; then
    log_info "Helm release $helm_name exists. Upgrading..."

    # Build upgrade command
    local upgrade_cmd="helm upgrade $helm_name $helm_chart -f $values_file -f $upgrade_file"

    # Add additional --set arguments if provided
    if [[ -n "$additional_set_args" ]]; then
      upgrade_cmd+=" $additional_set_args"
    fi

    # Execute upgrade
    eval $upgrade_cmd

    # Wait for deployment to be ready
    helm status $helm_name
    if [[ $? -eq 0 ]]; then
      log_success "Helm upgrade completed successfully"
    else
      log_warn "Helm upgrade may have issues, checking status..."
      helm status $helm_name
    fi
  else
    log_info "Helm release $helm_name does not exist. Installing..."

    # Build install command
    local install_cmd="helm install $helm_name $helm_chart -f $values_file"

    # Add additional --set arguments if provided
    if [[ -n "$additional_set_args" ]]; then
      install_cmd+=" $additional_set_args"
    fi

    # Execute install
    eval $install_cmd
  fi

  # Clean up the temporary values file
  rm $values_file
  rm $upgrade_file

  log_success "Helm updates completed for $helm_name."
}

# =============================================================================
# IMAGE PULL SECRETS MANAGEMENT
# =============================================================================

# Function to ensure imagePullSecrets are configured for a deployment or statefulset
# This provides centralized management of Artifactory access across all deployments
ensure_image_pull_secrets() {
  local resource_type=$1     # "deployment" or "statefulset"
  local resource_name=$2     # Name of the deployment/statefulset
  local namespace=${3:-$OC_PROJECT}  # Optional namespace (defaults to current project)

  # Get the secret name from environment variable with fallback
  local secret_name="${ARTIFACTORY_PULL_SECRET:-artifactory-m950-learning}"

  log_info "🔐 Ensuring imagePullSecrets for $resource_type/$resource_name"

  # Check if the resource exists
  if ! oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
    log_warn "Resource $resource_type/$resource_name not found in namespace $namespace"
    return 1
  fi

  # Check if imagePullSecrets already exist
  local existing_secrets
  existing_secrets=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}' 2>/dev/null)

  if [[ "$existing_secrets" == *"$secret_name"* ]]; then
    log_debug "✅ imagePullSecrets already configured with $secret_name"
    return 0
  fi

  log_info "Adding imagePullSecrets: $secret_name"

  # Check if imagePullSecrets field exists at all
  local has_image_pull_secrets
  has_image_pull_secrets=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.spec.template.spec.imagePullSecrets}' 2>/dev/null)

  if [[ -z "$has_image_pull_secrets" || "$has_image_pull_secrets" == "null" ]]; then
    # No imagePullSecrets field exists, create it
    log_debug "Creating new imagePullSecrets field"
    oc patch "$resource_type" "$resource_name" -n "$namespace" --type='json' -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/imagePullSecrets",
        "value": [{"name": "'"$secret_name"'"}]
      }
    ]'
  else
    # imagePullSecrets field exists, append to it
    log_debug "Appending to existing imagePullSecrets"
    oc patch "$resource_type" "$resource_name" -n "$namespace" --type='json' -p='[
      {
        "op": "add",
        "path": "/spec/template/spec/imagePullSecrets/-",
        "value": {"name": "'"$secret_name"'"}
      }
    ]'
  fi

  local patch_result=$?
  if [[ $patch_result -eq 0 ]]; then
    log_success "Successfully added imagePullSecrets: $secret_name"
    return 0
  else
    log_error "Failed to add imagePullSecrets to $resource_type/$resource_name"
    return 1
  fi
}

# Function to ensure imagePullSecrets for multiple resources
ensure_image_pull_secrets_batch() {
  local namespace=${1:-$OC_PROJECT}
  shift
  local resources=("$@")  # Array of "type/name" pairs

  log_info "🔐 Batch ensuring imagePullSecrets for ${#resources[@]} resources"

  local failed_count=0
  local success_count=0

  for resource in "${resources[@]}"; do
    local resource_type="${resource%/*}"
    local resource_name="${resource#*/}"

    if ensure_image_pull_secrets "$resource_type" "$resource_name" "$namespace"; then
      ((success_count++))
    else
      ((failed_count++))
    fi
  done

  log_info "📊 imagePullSecrets batch operation completed:"
  log_info "  ✅ Successful: $success_count"
  if [[ $failed_count -gt 0 ]]; then
    log_warn "  ❌ Failed: $failed_count"
  fi

  return $failed_count
}

# Function to automatically ensure imagePullSecrets for common deployment types
ensure_artifactory_access() {
  local namespace=${1:-$OC_PROJECT}

  log_info "🏭 Ensuring Artifactory access for common deployments in namespace: $namespace"

  # Define common resources that need Artifactory access
  local common_resources=(
    "deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME"
    "statefulset/$DB_DEPLOYMENT_NAME"
    "statefulset/$REDIS_NAME-node"
    "deployment/$REDIS_PROXY_NAME"
    "deployment/maintenance-message"
  )

  # Filter out resources that actually exist
  local existing_resources=()
  for resource in "${common_resources[@]}"; do
    local resource_type="${resource%/*}"
    local resource_name="${resource#*/}"

    if [[ -n "$resource_name" ]] && oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
      existing_resources+=("$resource")
      log_debug "Found existing resource: $resource"
    else
      log_debug "Resource not found (skipping): $resource"
    fi
  done

  if [[ ${#existing_resources[@]} -eq 0 ]]; then
    log_warn "No common deployments found that need Artifactory access"
    return 0
  fi

  log_info "Processing ${#existing_resources[@]} existing resources..."
  ensure_image_pull_secrets_batch "$namespace" "${existing_resources[@]}"
}

# =============================================================================
# PVC MANAGEMENT AND EXPANSION FUNCTIONS
# =============================================================================

# Function to check if a StorageClass supports volume expansion
check_storage_class_expansion() {
  local pvc_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Get the StorageClass name from the PVC
  local storage_class
  storage_class=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)

  if [[ -z "$storage_class" ]]; then
    log_error "❌ Could not determine StorageClass for PVC: $pvc_name"
    return 1
  fi

  # Check if the StorageClass allows volume expansion
  local allows_expansion
  allows_expansion=$(oc get storageclass "$storage_class" -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null)

  if [[ "$allows_expansion" == "true" ]]; then
    log_debug "✅ StorageClass '$storage_class' supports volume expansion"
    return 0
  else
    log_warn "⚠️ StorageClass '$storage_class' does not support volume expansion"
    log_warn "   PVC: $pvc_name"
    log_warn "   This may require manual intervention or StorageClass update"
    return 1
  fi
}

# Function to convert PVC capacity to consistent units (MiB)
convert_capacity_to_mib() {
  local capacity="$1"

  # Remove whitespace
  capacity=$(echo "$capacity" | tr -d '[:space:]')

  # Extract number and unit
  local value unit
  if [[ "$capacity" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    log_error "❌ Invalid capacity format: $capacity"
    return 1
  fi

  # Convert to MiB
  case "${unit^^}" in
    ""|"MIB"|"MI")
      echo "$value"
      ;;
    "GIB"|"GI"|"G")
      echo $((value * 1024))
      ;;
    "TIB"|"TI"|"T")
      echo $((value * 1024 * 1024))
      ;;
    "KIB"|"KI"|"K")
      echo $((value / 1024))
      ;;
    *)
      log_error "❌ Unsupported capacity unit: $unit"
      return 1
      ;;
  esac
}

# Function to get current PVC capacity in MiB
get_pvc_capacity_mib() {
  local pvc_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  local capacity
  capacity=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.status.capacity.storage}' 2>/dev/null)

  if [[ -z "$capacity" ]]; then
    log_error "❌ Could not get capacity for PVC: $pvc_name"
    return 1
  fi

  convert_capacity_to_mib "$capacity"
}

# Function to expand a single PVC
expand_pvc() {
  local pvc_name="$1"
  local target_size_mib="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local dry_run="${4:-false}"

  log_info "🔍 Checking PVC: $pvc_name"

  # Check if PVC exists
  if ! oc get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
    log_warn "⚠️ PVC not found: $pvc_name (may be created by StatefulSet later)"
    return 0  # Not an error - PVC might not exist yet
  fi

  # Check StorageClass supports expansion
  if ! check_storage_class_expansion "$pvc_name" "$namespace"; then
    log_warn "⚠️ Skipping PVC expansion (StorageClass limitation): $pvc_name"
    return 1
  fi

  # Get current capacity
  local current_size_mib
  current_size_mib=$(get_pvc_capacity_mib "$pvc_name" "$namespace")
  if [[ $? -ne 0 ]]; then
    log_error "❌ Failed to get current capacity for: $pvc_name"
    return 1
  fi

  log_debug "   Current: ${current_size_mib}Mi, Target: ${target_size_mib}Mi"

  # Compare sizes
  if [[ $target_size_mib -eq $current_size_mib ]]; then
    log_debug "   ✅ PVC already at target size"
    return 0
  elif [[ $target_size_mib -lt $current_size_mib ]]; then
    log_warn "   ⚠️ Target size (${target_size_mib}Mi) is smaller than current (${current_size_mib}Mi)"
    log_warn "   PVC shrinking is not supported in Kubernetes - skipping"
    return 0
  fi

  # Expansion needed
  local size_increase=$((target_size_mib - current_size_mib))
  log_info "   📈 Expanding PVC from ${current_size_mib}Mi to ${target_size_mib}Mi (+${size_increase}Mi)"

  if [[ "$dry_run" == "true" ]]; then
    log_info "   🔍 DRY RUN: Would expand PVC to ${target_size_mib}Mi"
    return 0
  fi

  # Perform the expansion
  if oc patch pvc "$pvc_name" -n "$namespace" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${target_size_mib}Mi\"}}}}" &>/dev/null; then
    log_success "   ✅ PVC expansion initiated: $pvc_name"

    # Wait for expansion to complete (with timeout)
    local attempts=0
    local max_attempts=30  # 5 minutes
    local expanded=false

    while [[ $attempts -lt $max_attempts ]]; do
      local new_size_mib
      new_size_mib=$(get_pvc_capacity_mib "$pvc_name" "$namespace")

      if [[ $new_size_mib -ge $target_size_mib ]]; then
        log_success "   ✅ PVC expansion completed: ${new_size_mib}Mi"
        expanded=true
        break
      fi

      log_debug "   ⏳ Waiting for expansion... (${attempts}0s)"
      sleep 10
      ((attempts++))
    done

    if [[ "$expanded" == "false" ]]; then
      log_warn "   ⚠️ PVC expansion timeout - may still be in progress"
      log_warn "   Check: oc get pvc $pvc_name -n $namespace"
    fi

    return 0
  else
    log_error "   ❌ Failed to expand PVC: $pvc_name"
    return 1
  fi
}

# Function to expand PVCs for a StatefulSet based on CSV sizing
expand_statefulset_pvcs() {
  local statefulset_name="$1"
  local target_pvc_size_mib="$2"
  local expected_replica_count="$3"
  local namespace="${4:-$DEPLOY_NAMESPACE}"
  local dry_run="${5:-false}"

  log_info "🗄️ PVC Expansion Check for StatefulSet: $statefulset_name"
  log_info "   Target PVC Size: ${target_pvc_size_mib}Mi"
  log_info "   Expected Replicas: $expected_replica_count"

  # Verify StatefulSet exists
  if ! oc get statefulset "$statefulset_name" -n "$namespace" &>/dev/null; then
    log_error "❌ StatefulSet not found: $statefulset_name"
    return 1
  fi

  # Get current replica count
  local current_replicas
  current_replicas=$(oc get statefulset "$statefulset_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)

  if [[ -n "$current_replicas" && "$current_replicas" -ne 0 ]]; then
    log_warn "⚠️ StatefulSet has $current_replicas active replicas"
    log_warn "   PVC expansion is safer when replicas=0"
    log_warn "   Consider scaling down first to avoid sync issues during expansion"
  else
    log_success "✅ StatefulSet is scaled to 0 - safe for PVC expansion"
  fi

  # Find all PVCs for this StatefulSet
  local pvc_pattern="data-${statefulset_name}-"
  local pvcs
  pvcs=$(oc get pvc -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep "^${pvc_pattern}")

  if [[ -z "$pvcs" ]]; then
    log_warn "⚠️ No PVCs found matching pattern: ${pvc_pattern}*"
    log_info "   PVCs will be created when StatefulSet scales up"
    return 0
  fi

  local pvc_count=0
  local expansion_count=0
  local failed_count=0

  for pvc in $pvcs; do
    ((pvc_count++))

    if expand_pvc "$pvc" "$target_pvc_size_mib" "$namespace" "$dry_run"; then
      ((expansion_count++))
    else
      ((failed_count++))
    fi
  done

  log_info "📊 PVC Expansion Summary:"
  log_info "   Total PVCs: $pvc_count"
  log_info "   Expanded/Verified: $expansion_count"

  if [[ $failed_count -gt 0 ]]; then
    log_warn "   Failed: $failed_count"
    return 1
  fi

  log_success "✅ All PVCs ready for StatefulSet scaling"
  return 0
}

# Function to read CSV and expand PVCs for all StatefulSets
# WARNING: This function is deprecated and should NOT be called from right-sizing.sh
# It can break deployments where PVCs are preserved but pods are recreated (e.g., Redis)
# Use expand_mariadb_galera_pvcs() instead for specific MariaDB workflow
expand_pvcs_from_csv() {
  local csv_file="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local dry_run="${3:-false}"

  log_warn "⚠️ expand_pvcs_from_csv() is deprecated"
  log_warn "   This function should only be used for specific StatefulSet deployments"
  log_warn "   NOT for general right-sizing operations"

  if [[ ! -f "$csv_file" ]]; then
    log_error "❌ CSV file not found: $csv_file"
    return 1
  fi

  log_info "📋 Reading PVC sizing from: $csv_file"

  local total_sts=0
  local processed_sts=0
  local failed_sts=0

  # Read CSV and process StatefulSets (skip header)
  while IFS=, read -r deployment type pod_count max_pods pvc_count pvc_capacity cpu_req cpu_lim mem_req mem_lim cpu_scale; do
    # Skip header
    [[ "$deployment" == "Deployment" ]] && continue

    # Only process StatefulSets with PVCs
    if [[ "$type" == "sts" && "$pvc_capacity" -gt 0 ]]; then
      ((total_sts++))
      log_info ""
      log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

      if expand_statefulset_pvcs "$deployment" "$pvc_capacity" "$pod_count" "$namespace" "$dry_run"; then
        ((processed_sts++))
      else
        ((failed_sts++))
      fi
    fi
  done < <(tail -n +2 "$csv_file")

  log_info ""
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "📊 CSV-Based PVC Expansion Complete"
  log_info "   StatefulSets Found: $total_sts"
  log_info "   Successfully Processed: $processed_sts"

  if [[ $failed_sts -gt 0 ]]; then
    log_warn "   Failed: $failed_sts"
    return 1
  fi

  log_success "✅ All StatefulSet PVCs verified/expanded"
  return 0
}

# =============================================================================
# MARIADB GALERA SPECIFIC PVC EXPANSION
# =============================================================================

# Function to expand MariaDB Galera PVCs during scale-up
# Monitors for new PVCs as StatefulSet scales up and expands each to target size
#
# This function is specifically designed for MariaDB Galera's deployment workflow:
# 1. StatefulSet scaled to 0, replica PVCs deleted
# 2. Helm upgrade applied with replicas=0
# 3. StatefulSet scaled up to target replicas
# 4. This function watches for PVC creation and expands each immediately
#
# NOTE: This should NOT be used for other StatefulSets without careful consideration
expand_mariadb_galera_pvcs() {
  local statefulset_name="$1"
  local target_replicas="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  # Get target PVC size from CSV
  local csv_file="./openshift/${namespace}-sizing.csv"
  if [[ ! -f "$csv_file" ]]; then
    log_warn "⚠️ CSV file not found: $csv_file"
    return 1
  fi

  local target_pvc_size=$(grep "^${statefulset_name}," "$csv_file" | cut -d',' -f6)

  if [[ -z "$target_pvc_size" || "$target_pvc_size" -eq 0 ]]; then
    log_debug "No PVC size specified in CSV - skipping expansion"
    return 0
  fi

  # Convert MiB to Gi for oc patch command
  local target_pvc_size_gi=$(( (target_pvc_size + 1023) / 1024 ))

  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Monitoring PVCs during scale-up"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "   Watching for PVCs: data-${statefulset_name}-{0..${target_replicas}}"
  log_info "   Will expand to: ${target_pvc_size_gi}Gi"
  echo ""

  # Process each expected PVC (0 through target_replicas-1)
  for i in $(seq 0 $((target_replicas - 1))); do
    local pvc_name="data-${statefulset_name}-${i}"

    log_info "   [${i}/${target_replicas}] Waiting for PVC: $pvc_name"

    # Wait for PVC to be created (max 2 minutes per PVC)
    local wait_attempts=0
    local max_wait_attempts=24  # 2 minutes (24 * 5 seconds)

    while [[ $wait_attempts -lt $max_wait_attempts ]]; do
      if oc get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
        log_success "   PVC created: $pvc_name"

        # Get current PVC size
        local current_size=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.resources.requests.storage}')
        log_debug "      Current size: $current_size"

        # Patch PVC to target size
        log_info "      Patching PVC to ${target_pvc_size_gi}Gi..."
        if oc patch pvc "$pvc_name" -n "$namespace" -p "{\"spec\": {\"resources\": {\"requests\": {\"storage\": \"${target_pvc_size_gi}Gi\"}}}}" &>/dev/null; then
          # Verify the patch
          local new_size=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.resources.requests.storage}')
          local status_size=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.status.capacity.storage}' 2>/dev/null || echo "pending")

          log_success "      PVC patched successfully"
          log_debug "         Requested: $new_size"
          log_debug "         Status: $status_size"

          # Note: We don't wait for expansion to complete to reduce deployment time
          # Storage expansion happens asynchronously and typically completes quickly
          # The request is patched immediately, actual expansion happens in background
          if [[ "$status_size" == "pending" || "$status_size" != "${target_pvc_size_gi}Gi" ]]; then
            log_info "      PVC expansion will complete asynchronously"
          fi
        else
          log_warn "      Failed to patch PVC (may already be at target size)"
          log_warn "         Current: $current_size, Target: ${target_pvc_size_gi}Gi"
        fi

        break
      fi

      sleep 5
      ((wait_attempts++))
    done

    if [[ $wait_attempts -eq $max_wait_attempts ]]; then
      log_error "   Timeout waiting for PVC: $pvc_name"
      log_error "      This may indicate StatefulSet scaling issues"
      break
    fi

    echo ""
  done

  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_success "PVC expansion phase complete"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  return 0
}

