#!/bin/bash
# =============================================================================
# validation.sh - Resource Validation & Platform Utilities
# =============================================================================
# PURPOSE:
#   Provides validation functions for OpenShift resources, platform detection,
#   pod discovery, and resource format verification.
#
# CORE FUNCTIONS:
#   - validate_and_format_resource_value() - Ensure resource values are valid
#   - resource_exists() - Check if resource exists in namespace
#   - get_pods_for_resource() - Generic pod discovery by resource type
#   - is_openshift() / is_docker() - Platform detection
#   - platform_exec() / platform_cp() - Platform-agnostic operations
#
# USAGE:
#   source ./openshift/scripts/utils/validation.sh
#
#   # Validate CPU/memory values
#   cpu=$(validate_and_format_resource_value "500" "m")  # → "500m"
#
#   # Check if resource exists
#   if resource_exists "deployment/php" "$namespace"; then
#     ...
#   fi
#
#   # Get pods for a deployment
#   pods=$(get_pods_for_resource "deployment/php" "$namespace")
#
# DEPENDENCIES:
#   - logging.sh (log_* functions)
#
# =============================================================================

# =============================================================================
# RESOURCE VALUE VALIDATION
# =============================================================================

# Ensure OpenShift resource values are valid
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

# Enhanced validation function with format checking
validate_resource_format() {
  local key="$1"
  local value="$2"

  # Validate memory format (e.g., 512Mi, 2Gi, 100M)
  if [[ "$key" =~ memory|MEMORY ]]; then
    if [[ ! "$value" =~ ^[0-9]+[KMGT]i?$ ]]; then
      echo "false"
      return 1
    fi
  fi

  # Validate CPU format (e.g., 100m, 500m, 1, 2)
  if [[ "$key" =~ cpu|CPU ]]; then
    if [[ ! "$value" =~ ^[0-9]+m?$ ]]; then
      echo "false"
      return 1
    fi
  fi

  # Validate storage format (e.g., 10Gi, 50Gi, 1Ti)
  if [[ "$key" =~ storage|STORAGE|volume ]]; then
    if [[ ! "$value" =~ ^[0-9]+[KMGT]i?$ ]]; then
      echo "false"
      return 1
    fi
  fi

  echo "true"
  return 0
}

# =============================================================================
# RESOURCE EXISTENCE CHECKS
# =============================================================================

# Check if a resource exists in the namespace
resource_exists() {
  local resource="$1"  # Format: "type/name" or "type name"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Handle both "type/name" and "type name" formats
  local resource_type resource_name
  if [[ "$resource" == *"/"* ]]; then
    resource_type="${resource%%/*}"
    resource_name="${resource##*/}"
  else
    resource_type="$resource"
    resource_name="$2"
    namespace="${3:-$DEPLOY_NAMESPACE}"
  fi

  if oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
    return 0
  else
    return 1
  fi
}

# Wait for scale-down to complete
wait_for_scale_down() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local timeout="${4:-300}"  # Default: 5 minutes

  log_info "Waiting for $resource_type/$resource_name to scale to 0..."

  local elapsed=0
  while [[ $elapsed -lt $timeout ]]; do
    local current_replicas
    current_replicas=$(oc get "$resource_type" "$resource_name" \
      -n "$namespace" \
      -o jsonpath='{.status.replicas}' 2>/dev/null || echo "0")

    if [[ "$current_replicas" == "0" || -z "$current_replicas" ]]; then
      log_success "Scale-down complete"
      return 0
    fi

    log_debug "Current replicas: $current_replicas (waiting...)"
    sleep 5
    elapsed=$((elapsed + 5))
  done

  log_error "Timeout waiting for scale-down after ${timeout}s"
  return 1
}

# =============================================================================
# PLATFORM DETECTION & ABSTRACTION
# =============================================================================

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

# =============================================================================
# POD DISCOVERY BY RESOURCE TYPE
# =============================================================================

# Generic function to get pods for a resource
# Handles deployments, statefulsets, jobs, and fallback label selectors
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
      selector_labels=$(oc get deployment "$resource_name" -n "$namespace" \
        -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)

      if [[ -n "$selector_labels" && "$selector_labels" != "{}" ]]; then
        # Try to parse the matchLabels JSON and convert to label selector format
        local selector_string=""

        # First try with jq (this will work in Linux/OpenShift environment)
        if command -v jq >/dev/null 2>&1; then
          selector_string=$(echo "$selector_labels" | \
            jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || echo "")
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
          oc get pods -l "$selector_string" -n "$namespace" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
        else
          # Fallback to common deployment patterns
          local pods
          pods=$(oc get pods -l app="$resource_name" -n "$namespace" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          if [[ -z "$pods" ]]; then
            pods=$(oc get pods -l deployment="$resource_name" -n "$namespace" \
              -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          fi
          echo "$pods"
        fi
      else
        # No selector labels found, use common patterns
        local pods
        pods=$(oc get pods -l app="$resource_name" -n "$namespace" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -z "$pods" ]]; then
          pods=$(oc get pods -l deployment="$resource_name" -n "$namespace" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        fi
        echo "$pods"
      fi
      ;;
    "statefulset")
      # For statefulsets, get the selector labels from the statefulset itself
      local selector_labels
      selector_labels=$(oc get statefulset "$resource_name" -n "$namespace" \
        -o jsonpath='{.spec.selector.matchLabels}' 2>/dev/null)

      if [[ -n "$selector_labels" && "$selector_labels" != "{}" ]]; then
        local selector_string=""

        # Try with jq first (works in Linux/OpenShift)
        if command -v jq >/dev/null 2>&1; then
          selector_string=$(echo "$selector_labels" | \
            jq -r 'to_entries | map("\(.key)=\(.value)") | join(",")' 2>/dev/null || echo "")
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
          oc get pods -l "$selector_string" -n "$namespace" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
        else
          # Fallback to common statefulset patterns
          local pods
          pods=$(oc get pods -l app.kubernetes.io/name="$resource_name" -n "$namespace" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          if [[ -z "$pods" ]]; then
            pods=$(oc get pods -l app="$resource_name" -n "$namespace" \
              -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          fi
          echo "$pods"
        fi
      else
        # No selector labels, use common patterns
        local pods
        pods=$(oc get pods -l app.kubernetes.io/name="$resource_name" -n "$namespace" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -z "$pods" ]]; then
          pods=$(oc get pods -l app="$resource_name" -n "$namespace" \
            -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        fi
        echo "$pods"
      fi
      ;;
    "job")
      oc get pods -l job-name="$resource_name" -n "$namespace" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null
      ;;
    *)
      # Fallback: try multiple common selectors
      local pods

      # Try app label first
      pods=$(oc get pods -l app="$resource_name" -n "$namespace" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

      # Try app.kubernetes.io/name if app didn't work
      if [[ -z "$pods" ]]; then
        pods=$(oc get pods -l app.kubernetes.io/name="$resource_name" -n "$namespace" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      fi

      # Try deployment label if others didn't work
      if [[ -z "$pods" ]]; then
        pods=$(oc get pods -l deployment="$resource_name" -n "$namespace" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      fi

      # Try deploymentconfig label (OpenShift specific)
      if [[ -z "$pods" ]]; then
        pods=$(oc get pods -l deploymentconfig="$resource_name" -n "$namespace" \
          -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
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
  if ! oc get deployment "$deployment_name" -n "$namespace" &>/dev/null; then
    log_error "Deployment '$deployment_name' does not exist in namespace '$namespace'"
    return 1
  fi

  log_info "Deployment exists. Checking selector labels..."

  # Get and display selector labels
  local selector_labels
  selector_labels=$(oc get deployment "$deployment_name" -n "$namespace" \
    -o jsonpath='{.spec.selector.matchLabels}')

  echo_field "Selector Labels" "$selector_labels"

  # Try to get pods using the deployment's selector
  log_info "Attempting pod discovery..."
  local pods
  pods=$(get_pods_for_resource "deployment/$deployment_name" "$namespace")

  if [[ -n "$pods" ]]; then
    log_success "Found pods: $pods"
  else
    log_warn "No pods found. Checking all pods in namespace..."
    oc get pods -n "$namespace" | grep "$deployment_name" || \
      log_error "No pods matching deployment name pattern"
  fi
}

# =============================================================================
# SECRET VALUE VALIDATION
# =============================================================================

validate_secret_values() {
  local secret_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local required_keys="${3:-}"  # Comma-separated list of required keys

  if ! resource_exists "secret/$secret_name" "$namespace"; then
    log_error "Secret '$secret_name' does not exist in namespace '$namespace'"
    return 1
  fi

  if [[ -z "$required_keys" ]]; then
    log_debug "No required keys specified for validation"
    return 0
  fi

  # Convert comma-separated list to array
  IFS=',' read -r -a key_array <<< "$required_keys"

  local missing_keys=()
  for key in "${key_array[@]}"; do
    # Trim whitespace
    key=$(echo "$key" | xargs)

    # Check if key exists in secret
    if ! oc get secret "$secret_name" -n "$namespace" \
         -o jsonpath="{.data.$key}" 2>/dev/null | grep -q .; then
      missing_keys+=("$key")
    fi
  done

  if [[ ${#missing_keys[@]} -gt 0 ]]; then
    log_error "Secret '$secret_name' is missing required keys: ${missing_keys[*]}"
    return 1
  fi

  log_success "Secret '$secret_name' validation passed"
  return 0
}
