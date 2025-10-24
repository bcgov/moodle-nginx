#!/bin/bash

# OpenShift Utilities Module
# Contains core OpenShift operations, resource management, maintenance mode,
# secret management, logging, and validation functions

# =============================================================================
# RESOURCE MANAGEMENT FUNCTIONS
# =============================================================================

# Function to dynamically determine expected replica count from Kubernetes resource
get_expected_replica_count() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Extract resource name from selector (e.g., "app.kubernetes.io/name=mariadb-galera" -> "mariadb-galera")
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Check StatefulSet first (most common for databases)
  if oc get statefulset "$resource_name" -n "$namespace" &> /dev/null; then
    local replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [[ -n "$replicas" && "$replicas" =~ ^[0-9]+$ && "$replicas" -gt 0 ]]; then
      echo "$replicas"
      return 0
    else
      echo "❌ Error: StatefulSet $resource_name exists but has invalid replica count: '$replicas'" >&2
      return 1
    fi
  fi

  # Check Deployment as fallback
  if oc get deployment "$resource_name" -n "$namespace" &> /dev/null; then
    local replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [[ -n "$replicas" && "$replicas" =~ ^[0-9]+$ && "$replicas" -gt 0 ]]; then
      echo "$replicas"
      return 0
    else
      echo "❌ Error: Deployment $resource_name exists but has invalid replica count: '$replicas'" >&2
      return 1
    fi
  fi

  echo "❌ Error: No StatefulSet or Deployment found for resource name: $resource_name (from selector: $selector)" >&2
  return 1
}

get_replicas() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Determine resource type and get current replicas
  local resource_type=""
  local original_replicas=""

  if oc get statefulset "$resource_name" -n "$namespace" &> /dev/null; then
    resource_type="statefulset"
    original_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}')
  elif oc get deployment "$resource_name" -n "$namespace" &> /dev/null; then
    resource_type="deployment"
    original_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}')
  else
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - No Resource" "Could not find StatefulSet or Deployment for selector: $selector (resource: $resource_name)" "error" "$namespace"
    return 1
  fi

  return $original_replicas;
}

# Function to check if StatefulSet/Deployment has all replicas available and ready
check_resource_ready() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Extract resource name from selector
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Check StatefulSet first
  if oc get statefulset "$resource_name" -n "$namespace" &> /dev/null; then
    local spec_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    local ready_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    local available_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)

    if [[ -n "$spec_replicas" && "$spec_replicas" =~ ^[0-9]+$ &&
          -n "$ready_replicas" && "$ready_replicas" =~ ^[0-9]+$ &&
          -n "$available_replicas" && "$available_replicas" =~ ^[0-9]+$ ]]; then
      if [[ "$spec_replicas" -eq "$ready_replicas" && "$spec_replicas" -eq "$available_replicas" ]]; then
        echo "✅ StatefulSet $resource_name: $available_replicas/$spec_replicas replicas ready and available"
        return 0
      else
        echo "⏳ StatefulSet $resource_name: $ready_replicas/$spec_replicas ready, $available_replicas available"
        return 1
      fi
    else
      echo "⏳ StatefulSet $resource_name: waiting for status to be available..."
      return 1
    fi
  fi

  # Check Deployment as fallback
  if oc get deployment "$resource_name" -n "$namespace" &> /dev/null; then
    local spec_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    local ready_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    local available_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)

    if [[ -n "$spec_replicas" && "$spec_replicas" =~ ^[0-9]+$ &&
          -n "$ready_replicas" && "$ready_replicas" =~ ^[0-9]+$ &&
          -n "$available_replicas" && "$available_replicas" =~ ^[0-9]+$ ]]; then
      if [[ "$spec_replicas" -eq "$ready_replicas" && "$spec_replicas" -eq "$available_replicas" ]]; then
        echo "✅ Deployment $resource_name: $available_replicas/$spec_replicas replicas ready and available"
        return 0
      else
        echo "⏳ Deployment $resource_name: $ready_replicas/$spec_replicas ready, $available_replicas available"
        return 1
      fi
    else
      echo "⏳ Deployment $resource_name: waiting for status to be available..."
      return 1
    fi
  fi

  echo "❌ Error: No StatefulSet or Deployment found for resource name: $resource_name (from selector: $selector)" >&2
  return 1
}

# Function to wait for resource to be ready with configurable timeout
wait_for_resource_ready() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local max_retries="${3:-30}"
  local wait_time="${4:-10}"
  local description="${5:-resource}"

  echo "⏳ Waiting for $description to be ready (selector: $selector)..."

  local retries=0
  while [[ $retries -lt $max_retries ]]; do
    if check_resource_ready "$selector" "$namespace"; then
      echo "✅ $description is ready"
      return 0
    else
      echo "    $description not ready yet... (retry $retries/$max_retries)"
    fi

    retries=$((retries + 1))
    sleep $wait_time
  done

  echo "⚠️ Timeout: $description did not become ready after $((max_retries * wait_time)) seconds"
  return 1
}

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
validate_and_format_resource_value() {
  local value=$1
  local unit=$2

  # Check if the value is a valid number
  if [[ $value =~ ^[1-9]+$ ]]; then
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
      log_warning "    Could not parse selector"
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

  # Construct the oc set resources command
  local cmd="oc set resources $type $deployment"
  local requests_set=false
  local limits_set=false

  if [[ "$cpu_request" != "null" ]]; then
    cmd+=" --requests=cpu=${cpu_request}"
    requests_set=true
  fi
  if [[ "$mem_request" != "null" ]]; then
    if $requests_set; then
      cmd+=",memory=${mem_request}"
    else
      cmd+=" --requests=memory=${mem_request}"
    fi
    requests_set=true
  fi
  if [[ "$cpu_limit" != "null" ]]; then
    cmd+=" --limits=cpu=${cpu_limit}"
    limits_set=true
  fi
  if [[ "$mem_limit" != "null" ]]; then
    if $limits_set; then
      cmd+=",memory=${mem_limit}"
    else
      cmd+=" --limits=memory=${mem_limit}"
    fi
    limits_set=true
  fi

  log_debug "Set: $cmd"
  $cmd
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

  # Extract resource type and name
  if [[ $resource == */* ]]; then
    local resource_type=${resource%%/*}
    local resource_name=${resource##*/}

    # Handle full API resource names (e.g., deployment.apps -> deployment)
    case "$resource_type" in
      "deployment.apps" | "deployments.apps") resource_type="deployment" ;;
      "statefulset.apps" | "statefulsets.apps") resource_type="statefulset" ;;
      "service.v1" | "services.v1") resource_type="service" ;;
      "job.batch" | "jobs.batch") resource_type="job" ;;
    esac
  else
    log_error "Invalid resource format: $resource. Expected format: <type>/<name>"
    return 1
  fi

  # Convert timeout to seconds for calculation
  local timeout_seconds=$(echo $timeout | sed 's/[a-zA-Z]*//g')
  max_retries=$((timeout_seconds / wait_time))

  log_info "Waiting for $resource to be $condition ($scale_direction). Max time: $timeout..."

  # Check if the resource exists before attempting to scale
  if ! oc get $resource_type $resource_name &> /dev/null; then
    log_warning "$resource_type/$resource_name does not exist. Skipping..."
    return 0
  fi

  if [[ $resource_type == "job" ]]; then
    handle_job_status "$resource_name" "$max_retries" "$retry_count" "$wait_time"
  else
    handle_deployment_status "$resource_name" "$condition" "$scale_direction" "$max_retries" "$retry_count" "$wait_time" "$resource_type"
  fi
}

# Function to wait for all pods in a deployment or statefulset to be running and check for errors
wait_for_deployment_without_errors() {
  local resource=$1 # e.g., deployment/web
  local error_search_string=${2:-error}
  local error_handler=${3:-delete_pod}
  local max_retries=${4:-30}
  local wait_time=${5:-30}

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

  # Use handle_pods_in_resource to manage pods
  if ! handle_pods_in_resource "$resource_type/$resource_name" "$DEPLOY_NAMESPACE" "check_pod_logs" "$error_search_string" "$error_handler" $max_retries $wait_time; then
    log_error "Errors detected in pods for $resource. Exiting..."
    return 1
  fi

  log_success "All pods in $resource are ready and error-free."
  return 0
}

check_timestamp() {
  IMAGE_REBUILD_TIME_LIMIT=${IMAGE_REBUILD_TIME_LIMIT:-86400} # Default to 24 hours
  local file_to_test=${1:-/var/www/html/index.php}
  local default_rerun_block_seconds=0 # Default to never blocking reruns
  local rerun_block_seconds=${IMAGE_REBUILD_TIME_LIMIT:-$default_rerun_block_seconds}

  log_info "Checking last time maintenance script was run..."

  # Check if the environment variable is set and valid
  if ! [[ "$rerun_block_seconds" =~ ^[0-9]+$ ]]; then
    log_warning "Invalid IMAGE_REBUILD_TIME_LIMIT value ($IMAGE_REBUILD_TIME_LIMIT). Using default value."
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
    log_warning "No file found to test last run time ($file_to_test)."
    return 0
  fi
}

# =============================================================================
# LOGGING AND ERROR HANDLING FUNCTIONS
# =============================================================================

# Function to log debug messages only when DEBUG_LEVEL is set to DEBUG
log_debug() {
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    echo "🔍 Debug: $*"
  fi
}

# Function to log info messages (always shown)
log_info() {
  echo "ℹ️  $*"
}

# Function to log warning messages (always shown)
log_warn() {
  echo "⚠️  $*"
}

# Function to log error messages (always shown)
log_error() {
  echo "❌ $*"
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
    LOGS=$(oc logs $pod -n $namespace -c $container)

    for error_search_string in "${error_strings[@]}"; do
      if echo "$LOGS" | grep -q "$error_search_string"; then
        if echo "$LOGS" | grep -q "Success"; then
          log_info "Connection was lost but reestablished. No need to restart the pod."
          continue
        else
          log_warning "Error found in pod logs: $error_search_string"
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
        log_warning "No pods found for deployment: $deployment"
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

# Enhanced logging function for critical events
log_critical_event() {
  local event_type="$1"
  local message="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')

  # Log to stdout with structured format for OpenShift log aggregation
  echo "CRITICAL_EVENT|${timestamp}|${namespace}|${event_type}|${message}"

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

  # Always log the critical event for aggregation
  log_critical_event "$event_type" "$message" "$namespace"
}

# Function to check logs for errors and restart if needed
check_and_restart_pod() {
  local selector="$1"
  local error_patterns="$2"

  log_info "Checking pods with selector: $selector"

  # Get all running pods matching the selector
  local pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$pods" ]]; then
    log_warning "No running pods found for selector: $selector"
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
      log_warning "No logs available for pod: $pod"
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
      log_warning "🔄 Restarting pod $pod due to error pattern: $found_pattern"
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
    log_warning "Could not determine route URL, skipping response verification"
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
    log_warning "$resource_type $resource_name does not exist. Skipping patch."
    return 1
  fi

  # Create temporary patch file
  local patch_file="/tmp/patch-${resource_type}-${resource_name}-$$.json"
  echo "$patch_operations" > "$patch_file"

  # Debug: Show what we're about to patch
  log_debug "Patch file contents: $(cat "$patch_file")"

  # Apply the patch
  if oc patch "$resource_type" "$resource_name" -n "$namespace" --type=json --patch-file="$patch_file"; then
    log_success "✅ Successfully applied patch to $resource_type/$resource_name"
    rm -f "$patch_file"
    return 0
  else
    log_warning "⚠️ Warning: Failed to apply patch to $resource_type/$resource_name"
    rm -f "$patch_file"
    return 1
  fi
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
      log_warning "Failed verification: $jsonpath = '$actual' (expected '$expected')"
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

  log_debug "🔍 Route patch details:"
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
      log_success "✅ Route patch verified: $route_name → $new_target"
    else
      log_error "❌ Route patch failed verification: $route_name → $new_target (expected: $target_service)"
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
    log_info "🔄 Redirecting all relevant routes to maintenance service..."
    patch_all_routes "$service_name"
  else
    log_info "🔄 Redirecting specific route $route_mode to $service_name..."
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
    log_info "🔄 Redirecting all relevant routes back to application service: $target_service_name"
    patch_all_routes "$target_service_name"
  else
    log_info "🔄 Redirecting specific route $route_mode to $target_service_name..."
    patch_route "$route_mode" "$target_service_name"
  fi

  log_success "✅ Route redirection completed - traffic now directed to $target_service_name"
  log_warning "⚠️ Note: Maintenance service scaling should be handled by caller after verification"
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
    log_error "❌ Secret '$secret_name' does not exist"
    return 1
  fi

  log_info "🔍 Validating secret '$secret_name' values..."

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

  log_info "🔐 Creating/updating secret '$secret_name'..."

  # Delete existing secret if it exists
  if oc get secret "$secret_name" -n "$namespace" &> /dev/null; then
    log_info "  Deleting existing secret..."
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

  log_info "🔧 Managing secret '$secret_name' with validation..."

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

# Function to restart deployments when secrets change (renamed from restart_deployment_for_secrets)
restart_deployment() {
  local deployment_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  log_info "🔄 Restarting deployment '$deployment_name' to pick up secret changes..."

  if oc get deployment "$deployment_name" -n "$namespace" &> /dev/null; then
    if oc rollout restart deployment/"$deployment_name" -n "$namespace"; then
      log_info "Deployment '$deployment_name' restart initiated"

      # Wait for the rollout to complete
      if oc rollout status deployment/"$deployment_name" -n "$namespace" --timeout=300s; then
        log_success "Deployment '$deployment_name' restart completed successfully"
        return 0
      else
        log_error "Deployment '$deployment_name' restart timed out or failed"
        return 1
      fi
    else
      log_error "Failed to restart deployment '$deployment_name'"
      return 1
    fi
  else
    log_error "Deployment '$deployment_name' not found"
    return 1
  fi
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

  while true; do
    # Check if the job has failed
    local job_failed=$(oc get jobs $job_name -o 'jsonpath={..status.failed}')
    if [[ $job_failed -gt 0 ]]; then
      log_error "Job $job_name has failed. Retrieving logs..."
      local pod_name=$(oc get pods --selector=job-name=$job_name -o jsonpath='{.items[0].metadata.name}')
      local error_log_text=$(oc logs $pod_name)
      log_error "Error log:"
      log_error "$error_log_text"
      return 1
    fi

    # Check if the job has succeeded
    local job_succeeded=$(oc get jobs $job_name -o 'jsonpath={..status.succeeded}')
    if [[ $job_succeeded -gt 0 ]]; then
      log_success "✔️ Job $job_name has completed successfully."
      return 0
    fi

    # Retry logic
    if [[ $retry_count -ge $max_retries ]]; then
      log_error "Timeout waiting for job $job_name to complete. Exiting..."
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
      log_warning "Failed to retrieve pods for resource: $resource_name. Retrying..."
      retry_count=$((retry_count + 1))
      if [[ $retry_count -ge $max_retries ]]; then
        log_error "Timeout waiting for condition '$condition' with resource: $resource_name. Exiting..."
        return 1
      fi
      sleep $wait_time
      continue
    fi

    if [[ $scale_direction == "up" ]]; then
      if [[ -z "$pods" ]]; then
        log_warning "No pods found for $resource_name. Retrying..."

        # Add debug info on first failure and every 10 retries
        if [[ $retry_count -eq 0 ]] || [[ $((retry_count % 10)) -eq 0 ]]; then
          log_debug "Debug: Investigating pod discovery issue..."
          debug_deployment_pods "$resource_name" "$DEPLOY_NAMESPACE"
        fi
      else
        local all_pods_ready=true
        for pod in $pods; do
          local output=$(oc wait --for=condition=$condition pod/$pod --timeout=${wait_time}s 2>&1)
          if ! echo "$output" | grep -q "condition met"; then
            all_pods_ready=false
            log_info "Pod $pod is not in '$condition' condition. Retrying..."
            break
          fi
        done
        if $all_pods_ready; then
          log_success "All pods for $resource_name are in '$condition' condition."
          return 0
        fi
      fi
    elif [[ $scale_direction == "down" ]]; then
      if [[ -z "$pods" ]]; then
        log_success "All pods for $resource_name have scaled down."
        return 0
      else
        log_info "Pods still exist for $resource_name ($pods). Retrying..."
      fi
    fi

    # Retry logic
    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      log_error "Timeout waiting for condition '$condition' with resource: $resource_name. Exiting..."
      return 1
    fi

    log_info "Retrying... ($(((retry_count + 1) * wait_time))/$((max_retries * wait_time)))"
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
          log_warning "Pod $pod has errors. Waiting for restart..."
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
      log_warning "Helm upgrade may have issues, checking status..."
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