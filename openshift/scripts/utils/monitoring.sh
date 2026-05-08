#!/bin/bash
# =============================================================================
# monitoring.sh - Wait & Deployment Monitoring Functions
# =============================================================================
# PURPOSE:
#   Provides comprehensive wait functions for resource deployments with
#   intelligent error handling, pod log checking, and integration with
#   cluster health monitoring.
#
# CORE FUNCTIONS:
#   - wait_for() - Universal wait for deploy/scale operations
#   - wait_for_deployment_without_errors() - Wait with error log checking
#   - check_timestamp() - Image rebuild time limit enforcement
#   - handle_deployment_status() - Deployment status monitoring
#   - handle_job_status() - Job completion monitoring
#   - handle_pods_in_resource() - Pod-level health checking
#   - normalize_resource_name() - Resource name formatting
#   - validate_resource_format() - Resource format validation
#   - create_or_update_helm_deployment() - Helm lifecycle management
#
# USAGE:
#   source ./openshift/scripts/utils/monitoring.sh
#
#   # Wait for deployment to scale up
#   wait_for "deployment/php" "ready" "600s" "up"
#
#   # Wait with error checking
#   wait_for_deployment_without_errors "deployment/php" "error" "delete_pod" 30 30
#
#   # Check if rebuild needed
#   if check_timestamp "/var/www/html/index.php"; then
#     echo "Rebuild required"
#   fi
#
# ENVIRONMENT VARIABLES:
#   CLUSTER_HEALTH_MONITORING - Enable cluster monitoring (default: YES)
#   IMAGE_REBUILD_TIME_LIMIT - Rebuild interval in seconds (default: 86400)
#   DEPLOY_NAMESPACE - Target namespace (required)
#
# DEPENDENCIES:
#   - logging.sh (log_* functions)
#   - cluster-health.sh (wait_with_cluster_monitoring)
#   - validation.sh (get_pods_for_resource, debug_deployment_pods)
#
# RELATED DOCS:
#   - docs/galera-deployment-best-practices.md
#   - docs/pod-health-monitor-coordination-strategy.md
# =============================================================================

# =============================================================================
# RESOURCE NAME NORMALIZATION
# =============================================================================

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
# WAIT FUNCTIONS
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
  local resource_type
  local resource_name
  resource_type=$(normalize_resource_name "$resource" "" "type")
  resource_name=$(normalize_resource_name "$resource" "" "extract")

  # Convert timeout to seconds for calculation
  local timeout_seconds
  timeout_seconds=$(echo "$timeout" | sed 's/[a-zA-Z]*//g')
  max_retries=$((timeout_seconds / wait_time))

  log_info "Waiting for $resource to be $condition ($scale_direction). Max time: $timeout..."

  # Check if the resource exists before attempting to scale
  if ! oc get "$resource_type" "$resource_name" &>/dev/null; then
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
  if ! oc get "$resource_type" "$resource_name" &>/dev/null; then
    log_error "$resource_type/$resource_name not found"
    return 1
  fi

  # Get the desired replica count
  local desired_replicas
  desired_replicas=$(oc get "$resource_type" "$resource_name" -o jsonpath='{.spec.replicas}')
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
    if ! handle_pods_in_resource "$resource_type/$resource_name" "$DEPLOY_NAMESPACE" "check_pod_logs" "$error_search_string" "$error_handler" "$max_retries" "$wait_time"; then
      log_error "Errors detected in pods for $resource. Exiting..."
      return 1
    fi

    log_success "All pods in $resource are ready and error-free."
    return 0
  fi
}

# Check timestamp to enforce image rebuild time limit
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
  local last_modified_minutes=$(( ($(date +%s) - $(stat -c %Y "$file_to_test")) / 60 ))

  log_debug "Last modified time: $last_modified_minutes minutes ago"
  log_debug "Rerun block time: $rerun_hours hours"
  log_debug "Current time: $(date +%Y-%m-%dT%H:%M:%S)"
  log_debug "Current time (epoch): $(date +%s)"
  log_debug "Last modified time (epoch): $(stat -c %Y "$file_to_test")"
  log_debug "Difference in hours: $(( ($(date +%s) - $(stat -c %Y "$file_to_test")) / 3600 )) hours"

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
# STATUS HANDLERS
# =============================================================================

# Function to handle job-specific logic (with cluster health monitoring)
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

    local job_failed
    job_failed=$(oc get jobs "$job_name" -o 'jsonpath={..status.failed}')
    if [[ $job_failed -gt 0 ]]; then
      log_error "Job $job_name has failed. Retrieving logs..."
      local pod_name
      pod_name=$(oc get pods --selector=job-name="$job_name" -o jsonpath='{.items[0].metadata.name}')
      if [[ -n "$pod_name" ]]; then
        local error_log_text
        error_log_text=$(oc logs "$pod_name" 2>/dev/null || echo "No logs available")
        log_error "Error log:"
        log_error "$error_log_text"
      else
        log_warn "No pod found for job $job_name to retrieve logs"
      fi
      return 1
    fi

    # Check if the job has succeeded
    local job_succeeded
    job_succeeded=$(oc get jobs "$job_name" -o 'jsonpath={..status.succeeded}')
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
        local pod_name
        pod_name=$(oc get pods --selector=job-name="$job_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

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
        local pod_name
        pod_name=$(oc get pods --selector=job-name="$job_name" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [[ -n "$pod_name" ]]; then
          show_cluster_events "Pod" "$pod_name" "$DEPLOY_NAMESPACE"
        else
          show_cluster_events "Job" "$job_name" "$DEPLOY_NAMESPACE"
        fi
      fi

      return 1
    fi

    log_info "Waiting for job $job_name to complete... (Retry $retry_count/$max_retries)"
    sleep "$wait_time"
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
      sleep "$wait_time"
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
          local output
          output=$(oc wait --for=condition="$condition" pod/"$pod" --timeout="${wait_time}s" 2>&1)
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
    sleep "$wait_time"
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
    local pods
    pods=$(get_pods_for_resource "$resource" "$namespace")

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
    sleep "$wait_time"
  done
}

# =============================================================================
# HELM MANAGEMENT
# =============================================================================

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
    eval "$upgrade_cmd"

    # Wait for deployment to be ready
    helm status "$helm_name"
    if [[ $? -eq 0 ]]; then
      log_success "Helm upgrade completed successfully"
    else
      log_warn "Helm upgrade may have issues, checking status..."
      helm status "$helm_name"
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
    eval "$install_cmd"
  fi

  # Clean up the temporary values files
  rm "$values_file"
  rm "$upgrade_file"

  log_success "Helm updates completed for $helm_name."
}
