#!/bin/bash

timestamp_file='/var/www/html/last_migration_timestamp'

# Define error handling functions
delete_pod() {
  local pod=$1
  echo "Restarting (deleting) pod..."
  delete_resource_if_exists pod $pod
}

log_error_continue() {
  local pod=$1
  echo "Continuing..."
  # Add any additional error handling logic here
}

# Function to scale a deployment
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

# Function to check logs for a single pod
check_pod_logs() {
  local pod=$1
  local namespace=$2
  local error_search_strings=${3:-"error"}
  local error_handler=${4:-delete_pod}
  local log_file="/tmp/logs/check-pod-logs.log"

  # echo "DEBUG: pod='$pod' namespace='$namespace' error_search_strings='$error_search_strings' error_handler='$error_handler'"

  # Split the error_search_strings into an array
  IFS=',' read -r -a error_strings <<< "$error_search_strings"

  # Check for malformed variables
  if [[ -z "$pod" || -z "$namespace" ]]; then
    echo "ERROR: pod or namespace is empty!"
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
          echo "Connection was lost but reestablished. No need to restart the pod."
          continue
        else
          echo "Error found in pod logs: $error_search_string"
          $error_handler $pod
          return 1  # Return failure if an error was found and handled
        fi
      fi
    done
  done

  echo "No errors found in pod: $pod"
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

    echo "Checking logs: $deployment"

    while true; do
      local errors_detected=0

      # Get the list of pods in the deployment
      PODS=$(oc get pods -l $deployment -o jsonpath='{.items[*].metadata.name}')
      # echo "PODS: $PODS"

      # Check if PODS is empty
      if [ -z "$PODS" ]; then
        echo "No pods found for deployment: $deployment"
        break
      fi

      # Convert PODS to an array
      IFS=' ' read -r -a pod_array <<< "$PODS"
      # echo "Pod array: ${pod_array[@]}"
      # Get number of pods in the arrayu
      total_pods=$(echo $PODS | wc -w)

      for pod in "${pod_array[@]}"; do
        echo "Processing pod logs: $pod"

        if ! check_pod_logs "$pod" "$DEPLOY_NAMESPACE" "$error_search_strings" "$error_handler"; then
          errors_detected=$((errors_detected + 1))
          total_errors=$((total_errors + 1))

          # Wait for the pod to be fully restarted and stabilized
          echo "Waiting for pod $pod to restart and stabilize..."
          sleep $wait_time
          oc wait --for=condition=Ready pod/$pod --timeout=300s
          break
        fi
      done

      if [ $errors_detected -eq 0 ]; then
        echo "✔️ OK"
        break
      else
        echo "❌ Errors found: $total_errors."
        retry_count=$((retry_count + 1))
        if [ $retry_count -ge $max_retries ]; then
          echo "❌ Max retries reached. Exiting..."
          return 1
        fi
        echo "Waiting for pods to restart and stabilize..."
        sleep $wait_time
      fi
    done

    if [ $total_errors -ne 0 ]; then
      echo "❌ Errors detected: $total_errors"
    fi
  done

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

# Function to wait for all pods in a deployment
# or statefulset to be running and check for errors
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

  echo "Waiting for $resource to be ready and error-free..."

  # Check if the resource exists
  if ! oc get $resource_type $resource_name &> /dev/null; then
    echo "❌ Error from server (NotFound): $resource_type/$resource_name not found"
    return 1
  fi

  # Get the desired replica count
  local desired_replicas=$(oc get $resource_type $resource_name -o jsonpath='{.spec.replicas}')
  if [[ "$desired_replicas" == "0" ]]; then
    echo "✔️ $resource has scaled down to 0 replicas."
    return 0
  fi

  # Use handle_pods_in_resource to manage pods
  if ! handle_pods_in_resource "$resource_type/$resource_name" "$DEPLOY_NAMESPACE" "check_pod_logs" "$error_search_string" "$error_handler" $max_retries $wait_time; then
    echo "❌ Errors detected in pods for $resource. Exiting..."
    return 1
  fi

  echo "✔️ All pods in $resource are ready and error-free."
  return 0
}

# Function to deploy and enable maintenance mode
enable_maintenance_mode() {
  local service_name=$1
  local route_name=$2
  local route_timeout="60s"

  echo "Deploying maintenance mode: $route_name > $service_name"

  # Scale to 1 replica
  scale_deployment "deployment" "$service_name" 1 1

  # Create / update route
  deploy_resource_from_template ./openshift/web-route-template.yml \
    "APP=$APP" \
    "WEB_DEPLOYMENT_NAME=$WEB_DEPLOYMENT_NAME" \
    "APP_HOST_URL=$APP_HOST_URL" \
    "DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE" \

  # Redirect traffic
  # echo "Redirecting traffic: $route_name > $service_name"
  patch_route $route_name $service_name
}

# Function to disable maintenance mode
disable_maintenance_mode() {
  local route_name="moodle-web"
  local service_name="web"
  local maintenance_service_name="maintenance-message"

  echo "Disabling $maintenance_service_name..."

  # Redirect traffic back to application
  # echo "Redirecting traffic to: service/$service_name..."
  patch_route $route_name $service_name

  sleep 60

  # Scale to 0
  scale_deployment "deployment" "$maintenance_service_name" 0 0
}

# Function to manage maintenance mode
manage_maintenance_mode() {
  local action=$1
  local deployment_name=$2
  local route_name=$3
  local max_retries=${4:-5} # Default to 5 retries
  local wait_time=${5:-30} # Default to 30 seconds between retries
  local retry_count=0

  # Ensure Redis Proxy is ready before proceeding
  echo "Ensuring Redis Proxy is ready..."
  if ! wait_for_redis_proxy_ready "redis-proxy" "$DEPLOY_NAMESPACE" 30 10; then
    echo "❌ Redis Proxy is not ready. Exiting..."
    exit 1
  fi
  echo "✔️ Redis Proxy is ready."

  if [[ $action != "enable" && $action != "disable" ]]; then
    echo "Invalid action: $action. Use 'enable' or 'disable'."
    return 1
  fi

  local script_action="--$action"
  local expected_output=""
  local expected_output_first_run="Could not open input file"

  if [[ $action == "enable" ]]; then
    enable_maintenance_mode $deployment_name $route_name
    expected_output="Your site is currently in CLI maintenance mode"
  else
    disable_maintenance_mode $deployment_name
    expected_output="Maintenance mode has been disabled"
  fi

  echo "${action^} maintenance mode..."

  # Get an active pod from the Cron deployment
  echo "Getting an active pod from deployment/$CRON_NAME..."
  local cron_pod=$(oc get pods -l app=$CRON_NAME --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "$cron_pod" ]]; then
    echo "❌ No running pods found for deployment/$CRON_NAME. Skipping..."
    return 0
  fi
  echo "Using pod: $cron_pod"

  # Retry logic for the maintenance mode operation
  while true; do
    maintenance_output=$(oc exec -n $DEPLOY_NAMESPACE $cron_pod -- bash -c "php /var/www/html/admin/cli/maintenance.php $script_action" 2>&1)

    if echo "$maintenance_output" | grep -q "$expected_output"; then
      echo "✔️ Maintenance mode has been successfully ${action}d."
      return 0
    elif echo "$maintenance_output" | grep -q "$expected_output_first_run"; then
      echo "⚠️ Maintenance cannot be set on first run, skipping."
      return 0
    elif echo "$maintenance_output" | grep -q "Exception"; then
      echo "❌ Failed to ${action} maintenance mode. Error message: $maintenance_output"
    elif echo "$maintenance_output" | grep -q "Error"; then
      echo "❌ Failed to ${action} maintenance mode. Error message: $maintenance_output"
    elif echo "$maintenance_output" | grep -q "level=error"; then
      echo "❌ Failed to ${action} maintenance mode. Error message: $maintenance_output"
      exit 1
    else
      echo "Unexpected output while attempting to ${action} maintenance mode:"
      echo "$maintenance_output"
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Max retries reached. Failed to ${action} maintenance mode. Exiting..."
      exit 1
    fi

    echo "Retrying in $wait_time seconds... (Attempt $retry_count/$max_retries)"
    sleep $wait_time
  done
}

# Generic function to apply JSON patches to Kubernetes resources
apply_resource_patch() {
  local resource_type="$1"    # e.g., "statefulset", "deployment", "route"
  local resource_name="$2"    # e.g., "redis-node"
  local patch_operations="$3" # JSON array of patch operations as string
  local namespace="${4:-$DEPLOY_NAMESPACE}"
  local description="${5:-Applying patch}"

  echo "🔧 $description for $resource_type/$resource_name..."

  # Check if the resource exists
  if ! oc get "$resource_type" "$resource_name" -n "$namespace" &> /dev/null; then
    echo "⚠️ $resource_type $resource_name does not exist. Skipping patch."
    return 1
  fi

  # Create temporary patch file
  local patch_file="/tmp/patch-${resource_type}-${resource_name}-$$.json"
  echo "$patch_operations" > "$patch_file"

  # Apply the patch
  if oc patch "$resource_type" "$resource_name" -n "$namespace" --type=json --patch-file="$patch_file"; then
    echo "✅ Successfully applied patch to $resource_type/$resource_name"
    rm -f "$patch_file"
    return 0
  else
    echo "⚠️ Warning: Failed to apply patch to $resource_type/$resource_name"
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

  echo "🔍 Verifying patch results for $resource_type/$resource_name..."

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
      echo "✅ Verified: $jsonpath = $expected"
    else
      echo "⚠️ Failed verification: $jsonpath = '$actual' (expected '$expected')"
      all_verified=false
    fi
  done

  [[ "$all_verified" == "true" ]]
}

# Updated patch_route function using generic approach
patch_route() {
  local route_name="$1"
  local target_service="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  echo "Patching route $route_name to point to $target_service..."

  # Show current route target
  if oc get route "$route_name" -n "$namespace" &> /dev/null; then
    local current_target
    current_target=$(oc get route "$route_name" -n "$namespace" -o jsonpath='{.spec.to.name}' 2>/dev/null)
    echo "Current route: $current_target"
  fi

  # Create patch operation
  local patch_ops='[{"op": "replace", "path": "/spec/to/name", "value": "'"$target_service"'"}]'

  # Apply the patch using generic function
  if apply_resource_patch "route" "$route_name" "$patch_ops" "$namespace" "Updating route target"; then
    # Wait for the route change to take effect
    local max_retries=30
    local retry_count=0
    local wait_time=5

    while [[ $retry_count -lt $max_retries ]]; do
      # If the route is deleted or not yet created, skip waiting
      if ! oc get route "$route_name" -n "$namespace" &> /dev/null; then
        echo "⚠️ Route $route_name no longer exists during patch wait. Skipping further checks."
        return 0
      fi

      local current_target
      current_target=$(oc get route "$route_name" -n "$namespace" -o jsonpath='{.spec.to.name}')
      if [[ "$current_target" == "$target_service" ]]; then
        echo "✔️ Route $route_name successfully updated to $target_service."
        return 0
      fi

      echo "Waiting for route $route_name to update to $target_service... (attempt $((retry_count + 1))/$max_retries)"
      sleep $wait_time
      retry_count=$((retry_count + 1))
    done

    echo "❌ Route update to $target_service failed after $((max_retries * wait_time)) seconds."
    return 1
  else
    return 1
  fi
}

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
      echo "❌ Job $job_name has failed. Retrieving logs..."
      local pod_name=$(oc get pods --selector=job-name=$job_name -o jsonpath='{.items[0].metadata.name}')
      local error_log_text=$(oc logs $pod_name)
      echo "Error log:"
      echo "$error_log_text"
      return 1
    fi

    # Check if the job has succeeded
    local job_succeeded=$(oc get jobs $job_name -o 'jsonpath={..status.succeeded}')
    if [[ $job_succeeded -gt 0 ]]; then
      echo "✔️ Job $job_name has completed successfully."
      return 0
    fi

    # Retry logic
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Timeout waiting for job $job_name to complete. Exiting..."
      return 1
    fi

    echo "Waiting for job $job_name to complete... (Retry $retry_count/$max_retries)"
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

    # echo "Pods for resource $resource_name: $pods"

    if [[ $status -ne 0 ]]; then
      echo "❌ Failed to retrieve pods for resource: $resource_name. Retrying..."
      retry_count=$((retry_count + 1))
      if [[ $retry_count -ge $max_retries ]]; then
        echo "❌ Timeout waiting for condition '$condition' with resource: $resource_name. Exiting..."
        return 1
      fi
      sleep $wait_time
      continue
    fi

    if [[ $scale_direction == "up" ]]; then
      if [[ -z "$pods" ]]; then
        echo "No pods found for $resource_name. Retrying..."
      else
        local all_pods_ready=true
        for pod in $pods; do
          local output=$(oc wait --for=condition=$condition pod/$pod --timeout=${wait_time}s 2>&1)
          # echo "Executing: oc wait --for=condition=$condition pod/$pod --timeout=${wait_time}s"
          # echo "Status: $output"
          if ! echo "$output" | grep -q "condition met"; then
            all_pods_ready=false
            echo "Pod $pod is not in '$condition' condition. Retrying..."
            break
          fi
        done
        if $all_pods_ready; then
          echo "✔️ All pods for $resource_name are in '$condition' condition."
          return 0
        fi
      fi
    elif [[ $scale_direction == "down" ]]; then
      if [[ -z "$pods" ]]; then
        echo "✔️ All pods for $resource_name have scaled down."
        return 0
      else
        echo "Pods still exist for $resource_name ($pods). Retrying..."
      fi
    fi

    # Retry logic
    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Timeout waiting for condition '$condition' with resource: $resource_name. Exiting..."
      return 1
    fi

    echo "Retrying... ($(((retry_count + 1) * wait_time))/$((max_retries * wait_time)))"
    sleep $wait_time
  done
}

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
    echo "❌ Invalid resource format: $resource. Expected format: <type>/<name>"
    return 1
  fi

  # Convert timeout to seconds for calculation
  local timeout_seconds=$(echo $timeout | sed 's/[a-zA-Z]*//g')
  max_retries=$((timeout_seconds / wait_time))

  echo "Waiting for $resource to be $condition ($scale_direction). Max time: $timeout..."

  # Check if the resource exists before attempting to scale
  if ! oc get $resource_type $resource_name &> /dev/null; then
    echo "⚠️ $resource_type/$resource_name does not exist. Skipping..."
    return 0
  fi

  if [[ $resource_type == "job" ]]; then
    handle_job_status "$resource_name" "$max_retries" "$retry_count" "$wait_time"
  else
    handle_deployment_status "$resource_name" "$condition" "$scale_direction" "$max_retries" "$retry_count" "$wait_time" "$resource_type"
  fi
}

check_timestamp() {
  IMAGE_REBUILD_TIME_LIMIT=${IMAGE_REBUILD_TIME_LIMIT:-86400} # Default to 24 hours
  local file_to_test=${1:-/var/www/html/index.php}
  local default_rerun_block_seconds=0 # Default to never blocking reruns
  local rerun_block_seconds=${IMAGE_REBUILD_TIME_LIMIT:-$default_rerun_block_seconds}

  echo "Checking last time maintenance script was run..."

  # Check if the environment variable is set and valid
  if ! [[ "$rerun_block_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid IMAGE_REBUILD_TIME_LIMIT value ($IMAGE_REBUILD_TIME_LIMIT). Using default value."
    rerun_block_seconds=$default_rerun_block_seconds
  fi

  # If the value is 0, do not enforce the time limit
  if [ "$rerun_block_seconds" -eq 0 ]; then
    echo "IMAGE_REBUILD_TIME_LIMIT is set to 0. Time limit is not enforced."
    return 0
  fi

  local rerun_minutes=$((rerun_block_seconds / 60))
  local rerun_hours=$((rerun_minutes / 60))
  local last_modified_minutes=$(( ($(date +%s) - $(stat -c %Y $file_to_test)) / 60 ))

  echo "Last modified time: $last_modified_minutes minutes ago"
  # echo "Rerun block time: $rerun_minutes minutes"
  echo "Rerun block time: $rerun_hours hours"
  echo "Current time: $(date +%Y-%m-%dT%H:%M:%S)"
  echo "Current time (epoch): $(date +%s)"
  echo "Last modified time (epoch): $(stat -c %Y $file_to_test)"
  # echo "Last modified time (epoch): $(date -d "@$(stat -c %Y $file_to_test)" +%Y-%m-%dT%H:%M:%S)"
  # echo "Last modified time (epoch): $(date -d "@$(stat -c %Y $file_to_test)" +%s)"
  # echo "Difference: $(( $(date +%s) - $(stat -c %Y $file_to_test) )) seconds"
  echo "Difference in hours: $(( ($(date +%s) - $(stat -c %Y $file_to_test)) / 3600 )) hours"
  # echo "Difference in minutes: $(( ($(date +%s) - $(stat -c %Y $file_to_test)) / 60 )) minutes"

  # Check if the script has been run within the past hour
  if [ -f "$file_to_test" ]; then
    if [ "$last_modified_minutes" -lt "$rerun_minutes" ]; then
      echo "The script has been run within the past $rerun_hours hours."
      return 1
    else
      echo "The script has not been run within the past $rerun_hours hours."
      return 0
    fi
  else
    echo "No file found to test last run time ($file_to_test)."
    return 0
  fi
}

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

# Function to set resources for a deployment
set_resources() {
  local type=$1
  local deployment=$2
  local cpu_request=$3
  local mem_request=$4
  local cpu_limit=$5
  local mem_limit=$6

  echo "Setting resources for $type/$deployment..."
  echo "CPU Request: $cpu_request"
  echo "Memory Request: $mem_request"
  echo "CPU Limit: $cpu_limit"
  echo "Memory Limit: $mem_limit"

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

  echo "Set: $cmd"
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
    echo "Invalid HPA values. Exiting..."
    return 1
  fi

  echo "Creating HPA: $name > $target - Scale at $avg_value from $min_replicas to $max_replicas replicas"

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

  echo "Cre$pod--forating HPA from template:"
  # echo $(cat hpa.yaml)
  oc create -f hpa.yaml

  wait_for_deployment_without_errors "$kind/$target"

  return 0
}

# Function to create Redis services for each pod
create_redis_services() {
  local redis_name=$1

  echo "Deploy Redis Service for each pod ..."
  PODS=$(oc get pods -l app.kubernetes.io/name=$redis_name -o jsonpath='{.items[*].metadata.name}')
  for pod_name in $PODS; do
    sed "s/\${POD_NAME}/$pod_name/g" < ./openshift/redis-services.yml | oc apply -f -
    echo "Service created for: $pod_name"
  done
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

# Enhanced Galera cluster health check with better error handling and logging
check_galera_cluster_health() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-5}"

  send_notification "GALERA_HEALTH_CHECK_START" "Galera Health Check Starting" "Checking cluster health for selector: $selector" "info" "$namespace"

  # Get running pods using the selector
  local pods=( $(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[*].metadata.name}') )

  if [[ ${#pods[@]} -eq 0 ]]; then
    send_notification "GALERA_NO_PODS" "No Galera Pods Found" "No running Galera pods found for selector: $selector" "error" "$namespace"
    return 0
  fi

  echo "  🩺 Checking Galera cluster health for ${#pods[@]} pods..."

  local healthy_pods=0
  local uuids=()
  local sizes=()
  local states=()
  local detailed_status=""

  # Check each pod using existing utility function
  for pod in "${pods[@]}"; do
    if check_galera_pod_ready "$pod" "$namespace" "$expected_size"; then
      healthy_pods=$((healthy_pods + 1))
      echo "    ✅ $pod: healthy and synced"
    else
      echo "    ❌ $pod: unhealthy or not synced"
    fi

    # Get detailed status for split-brain detection
    local status_output
    get_mariadb_env_vars "$pod"
    status_output=$(oc exec -n "$namespace" "$pod" -- \
      mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" \
      -e "SHOW STATUS LIKE 'wsrep_cluster_state_uuid'; SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_local_state_comment';" \
      2>/dev/null) || continue

    local uuid=$(echo "$status_output" | awk '/wsrep_cluster_state_uuid/ {print $2}')
    local size=$(echo "$status_output" | awk '/wsrep_cluster_size/ {print $2}')
    local state=$(echo "$status_output" | awk '/wsrep_local_state_comment/ {print $2}')

    uuids+=("$uuid")
    sizes+=("$size")
    states+=("$state")
    detailed_status+="$pod: uuid=$uuid, size=$size, state=$state; "
  done

  # Analyze cluster consistency
  local unique_uuids=$(printf "%s\n" "${uuids[@]}" | sort | uniq | grep -v '^$' | wc -l)
  local unique_sizes=$(printf "%s\n" "${sizes[@]}" | sort | uniq | grep -v '^$' | wc -l)

  # Check for split-brain or inconsistency
  if [[ $unique_uuids -gt 1 || $unique_sizes -gt 1 ]]; then
    send_notification "GALERA_SPLIT_BRAIN_DETECTED" "🚨 Galera Split-Brain Detected!" "Split-brain detected! UUIDs: $unique_uuids, Sizes: $unique_sizes. Details: $detailed_status" "error" "$namespace"
    return 2  # Split-brain detected
  elif [[ $healthy_pods -lt $expected_size ]]; then
    send_notification "GALERA_UNHEALTHY_PODS" "Galera Pods Unhealthy" "Some pods unhealthy: $healthy_pods/$expected_size healthy. Details: $detailed_status" "warning" "$namespace"
    return 1  # Some pods unhealthy
  else
    echo "    ✅ Galera cluster healthy: all $healthy_pods pods synced and consistent"
    return 0  # All healthy
  fi
}

# Enhanced Galera sync function that works with selectors
wait_for_galera_cluster_sync() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-5}"
  local max_retries="${4:-30}"
  local wait_time="${5:-10}"

  echo "⏳ Waiting for Galera cluster to sync (selector: $selector, expected size: $expected_size)..."

  local retries=0
  while [[ $retries -lt $max_retries ]]; do
    # Get running pods using selector
    local pods=( $(oc get pods -l "$selector" --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[*].metadata.name}') )
    local pod_count=${#pods[@]}

    if [[ $pod_count -eq 0 ]]; then
      echo "    No running pods found yet... (retry $retries/$max_retries)"
      retries=$((retries + 1))
      sleep $wait_time
      continue
    fi

    if [[ $pod_count -lt $expected_size ]]; then
      echo "    $pod_count/$expected_size pods running, waiting for more... (retry $retries/$max_retries)"
      retries=$((retries + 1))
      sleep $wait_time
      continue
    fi

    # Check if all pods are Galera-ready
    local healthy_pods=0
    for pod in "${pods[@]}"; do
      if check_galera_pod_ready "$pod" "$namespace" "$expected_size"; then
        healthy_pods=$((healthy_pods + 1))
      fi
    done

    if [[ $healthy_pods -eq $expected_size ]]; then
      echo "✅ All $expected_size Galera pods are healthy and synced"
      return 0
    else
      echo "    $healthy_pods/$expected_size pods are Galera-ready... (retry $retries/$max_retries)"
    fi

    retries=$((retries + 1))
    sleep $wait_time
  done

  echo "⚠️ Timeout: Only $healthy_pods/$expected_size pods became Galera-ready after $((max_retries * wait_time)) seconds"
  return 1
}

# Function to auto-heal Galera cluster using existing utilities
auto_heal_galera_cluster() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  send_notification "GALERA_AUTO_HEAL_START" "🔧 Galera Auto-Heal Starting" "Initiating Galera auto-heal for selector: $selector" "healing" "$namespace"

  # Extract resource name from selector (e.g., "app.kubernetes.io/name=mariadb-galera" -> "mariadb-galera")
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Use existing function to determine resource type and get current replicas
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

  if [[ -z "$original_replicas" || "$original_replicas" == "0" ]]; then
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - Invalid Replicas" "Could not determine valid replica count for $resource_type: $resource_name" "error" "$namespace"
    return 1
  fi

  send_notification "GALERA_AUTO_HEAL_SCALING" "🔄 Starting Auto-Heal Process" "Auto-healing $resource_type/$resource_name: $original_replicas → 1 → $original_replicas replicas" "healing" "$namespace"

  # Step 1: Scale down to 1 replica (keeps one node as primary)
  echo "🔽 Step 1: Scaling down to 1 replica to establish primary node..."
  if ! scale_simple "$resource_type" "$resource_name" "1" "$namespace" "300s"; then
    send_notification "GALERA_AUTO_HEAL_FAILED" "Auto-Heal Failed - Scale to 1" "Failed to scale $resource_type/$resource_name to 1 replica" "error" "$namespace"
    return 1
  fi

  # Wait a bit for the remaining node to stabilize
  echo "⏸️  Waiting 30 seconds for primary node to stabilize..."
  sleep 30

  # Step 2: Scale back up to original replica count
  echo "🔼 Step 2: Scaling back up to $original_replicas replicas..."
  if ! scale_simple "$resource_type" "$resource_name" "$original_replicas" "$namespace" "600s"; then
    send_notification "GALERA_AUTO_HEAL_PARTIAL" "Auto-Heal Partial - Scale Up Failed" "Scaled to 1 but failed to scale back to $original_replicas replicas" "warning" "$namespace"
    return 1
  fi  # Step 3: Wait for Galera cluster to sync using enhanced utility
  echo "🔄 Step 3: Waiting for Galera cluster synchronization..."
  if wait_for_galera_cluster_sync "$selector" "$namespace" "$original_replicas" 60 15; then
    send_notification "GALERA_AUTO_HEAL_SUCCESS" "✅ Auto-Heal Successful" "Successfully auto-healed $resource_type/$resource_name: all $original_replicas replicas are healthy and synced" "success" "$namespace"
    return 0
  else
    send_notification "GALERA_AUTO_HEAL_PARTIAL" "⚠️ Auto-Heal Partial Success" "$resource_type/$resource_name scaled successfully but Galera sync verification failed" "warning" "$namespace"
    return 1
  fi
}

# Combined function for health check and auto-heal
check_and_heal_galera_cluster() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_size="${3:-5}"
  local auto_heal="${4:-true}"

  local health_status
  health_status=$(check_galera_cluster_health "$selector" "$namespace" "$expected_size")
  local health_code=$?

  case $health_code in
    0)
      echo "    ✅ Galera cluster is healthy"
      return 0
      ;;
    1)
      echo "    ⚠️  Some Galera pods are unhealthy but no split-brain detected"
      if [[ "$auto_heal" == "true" ]]; then
        auto_heal_galera_cluster "$selector" "$namespace"
        return $?
      fi
      return 1
      ;;
    2)
      echo "    🚨 Galera split-brain detected!"
      if [[ "$auto_heal" == "true" ]]; then
        auto_heal_galera_cluster "$selector" "$namespace"
        return $?
      fi
      return 2
      ;;
    *)
      log_critical_event "GALERA_CHECK_ERROR" "Unexpected health check result: $health_code"
      return 1
      ;;
  esac
}

# Function to check logs for errors and restart if needed
check_and_restart_pod() {
  local selector="$1"
  local error_patterns="$2"

  echo "🔍 Checking pods with selector: $selector"

  # Get all running pods matching the selector
  local pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$pods" ]]; then
    echo "⚠️  No running pods found for selector: $selector"
    return
  fi

  # Convert comma-separated patterns to array
  IFS=',' read -ra patterns <<< "$error_patterns"

  local pods_restarted=0

  for pod in $pods; do
    echo "  📋 Checking pod: $pod"

    # Get recent logs (last 50 lines to avoid overwhelming output)
    local logs=$(oc logs "$pod" --tail=50 2>/dev/null)

    if [[ -z "$logs" ]]; then
      echo "    ⚠️  No logs available for pod: $pod"
      continue
    fi

    local errors_found=false
    local found_pattern=""

    # Check for each error pattern
    for pattern in "${patterns[@]}"; do
      pattern=$(echo "$pattern" | xargs) # trim whitespace
      if [[ -n "$pattern" && "$logs" == *"$pattern"* ]]; then
        echo "    🚨 ERROR DETECTED in $pod: Found pattern '$pattern'"
        errors_found=true
        found_pattern="$pattern"
        break
      fi
    done

    if [[ "$errors_found" == "true" ]]; then
      echo "    🔄 Restarting pod: $pod"
      if oc delete pod "$pod" --wait=false; then
        echo "    ✅ Pod $pod deletion initiated successfully"
        pods_restarted=$((pods_restarted + 1))

        # Send notification for pod restart
        send_notification "POD_RESTART" "Pod Restarted Due to Error" "Pod $pod restarted due to error pattern: '$found_pattern'. Selector: $selector" "warning" "$DEPLOY_NAMESPACE"
      else
        echo "    ❌ Failed to delete pod: $pod"
        send_notification "POD_RESTART_FAILED" "Failed to Restart Pod" "Failed to restart pod $pod with selector: $selector" "error" "$DEPLOY_NAMESPACE"
      fi
    else
      echo "    ✅ Pod $pod is healthy (no error patterns found)"
    fi
  done

  # Send summary notification if multiple pods were restarted
  if [[ $pods_restarted -gt 1 ]]; then
    send_notification "MULTIPLE_POD_RESTARTS" "Multiple Pods Restarted" "$pods_restarted pods with selector '$selector' were restarted due to errors" "warning" "$DEPLOY_NAMESPACE"
  fi
}

# Function to create or update a ConfigMap
create_or_update_configmap() {
  local configmap_name=$1
  shift
  local file_paths=("$@")

  delete_resource_if_exists configmap $configmap_name
  echo "Creating ConfigMap: $configmap_name"

  # Construct the oc create configmap command with multiple --from-file flags
  local create_cmd="oc create configmap $configmap_name"
  for file_path in "${file_paths[@]}"; do
    create_cmd+=" --from-file=$file_path"
  done

  # Execute the command
  # echo "Executing: $create_cmd"
  eval $create_cmd
}

# Function to create or update a Helm deployment
create_or_update_helm_deployment() {
  local helm_name=$1
  local helm_chart=$2
  local values_file=$3
  local upgrade_file=$4
  local additional_set_args="${5:-}"  # Optional: additional --set arguments

  if helm list -q | grep -q "^$helm_name$"; then
    echo "Helm deployment found. Updating..."
    helm_repo_update_response=$(helm repo update 2>&1)

    # Build the helm upgrade command with optional additional set arguments
    local upgrade_cmd="helm upgrade --reuse-values -f $upgrade_file"
    if [[ -n "$additional_set_args" ]]; then
      upgrade_cmd="$upgrade_cmd $additional_set_args"
    fi
    upgrade_cmd="$upgrade_cmd $helm_name $helm_chart"

    helm_upgrade_response=$(eval $upgrade_cmd 2>&1)

    # Output the response for debugging purposes
    # echo "1. $helm_upgrade_response"

    # Check if the helm upgrade command failed
    if [[ $? -ne 0 ]]; then
      echo "Helm upgrade failed with the following output:"
      echo "2. $helm_upgrade_response"
      exit 1
    fi

    # Check the Helm deployment for errors
    if [[ $helm_upgrade_response =~ "Error" ]]; then
      echo "❌ Helm upgrade FAILED."
      echo "3. $helm_upgrade_response"
      exit 1
    fi

    if [[ `oc describe sts/$helm_name-node 2>&1` =~ "NotFound" ]]; then
      echo "Helm chart ($helm_name) exists, but StatefulSet ($helm_name-node) was NOT FOUND."

      if [[ `oc describe deployment/$helm_name-backup-storage 2>&1` =~ "NotFound" ]]; then
        echo "Helm chart ($helm_name) exists, but Deployment ($helm_name-backup-storage) was NOT FOUND."
        echo "Helm upgrade failed. Exiting..."
        exit 1
      fi
    fi
  else
    echo "Helm deployment ($helm_name) NOT FOUND. Beginning deployment..."

    # Build the helm install command with optional additional set arguments
    local install_cmd="helm install --values $values_file"
    if [[ -n "$additional_set_args" ]]; then
      install_cmd="$install_cmd $additional_set_args"
    fi
    install_cmd="$install_cmd $helm_name $helm_chart"

    eval $install_cmd
  fi

  # Clean up the temporary values file
  rm $values_file
  rm $upgrade_file

  echo "Helm updates completed for $helm_name."
}

# Function to delete a resource if it exists
delete_resource_if_exists() {
  local resource_type=$1
  local resource_name=$2

  echo "Checking if $resource_type exists: $resource_name"

  # Use oc get to check if the resource exists
  if oc get $resource_type $resource_name &> /dev/null; then
    echo "$resource_type exists... Deleting: $resource_name"
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
  # echo "Executing: $process_cmd"

  # Process the template and print the output for debugging
  local processed_template
  processed_template=$(eval $process_cmd)
  # echo "Processed template:"
  # echo "$processed_template"

  # Extract the deployment name from the processed template
  local deployment_name=$(echo "$processed_template" | jq -r '.items[] | select(.kind == "Deployment") | .metadata.name')

  # Delete the existing deployment if it exists
  if oc get deployment "$deployment_name" &> /dev/null; then
    echo "Deleting existing deployment: $deployment_name"
    oc delete deployment "$deployment_name"
  fi

  # Apply the processed template and capture output
  local apply_output
  apply_output=$(echo "$processed_template" | oc apply -f - 2>&1)

  # Check for "invalid" in the apply output (post-apply)
  if echo "$apply_output" | grep -qi "invalid"; then
    echo "❌ ERROR: 'oc apply' has detected an 'invalid' deployment. Aborting."
    echo "$apply_output"
    exit 1
  fi
}

check_logs_for_pattern() {
  local pod_name=$1
  local namespace=$2
  local pattern_list=$3

  local logs
  logs=$(oc logs "$pod_name" -n "$namespace" 2>&1)

  IFS=',' read -ra patterns <<< "$pattern_list"
  for pattern in "${patterns[@]}"; do
    # Use -w for whole word, -i for case-insensitive, and anchor if needed
    if echo "$logs" | grep -i -q "$pattern"; then
      echo "Pattern matched: $pattern"
      return 0
    fi
  done
  return 1
}

wait_for_galera_sync() {
  local sts_name=$1
  local namespace=$2
  local expected_size=${3:-5}
  local max_retries=${4:-60}
  local wait_time=${5:-30}

  for ((i=1; i<=expected_size; i++)); do
    echo "Scaling $sts_name to $i replicas..."
    oc scale statefulset/$sts_name -n $namespace --replicas=$i

    # Wait for the new pod to be healthy
    local pod_name="${sts_name}-$((i-1))"
    local retries=0

    while true; do
      if check_galera_pod_ready "$pod_name" "$namespace" "$i"; then
        echo "$pod_name is healthy and joined the cluster."
        break
      fi

      retries=$((retries+1))
      if [[ $retries -ge $max_retries ]]; then
        echo "❌ Timeout waiting for $pod_name to be healthy."
        return 1
      fi
      echo "Waiting for $pod_name to be healthy... ($retries/$max_retries)"
      sleep $wait_time
    done
  done

  echo "✔️ All Galera pods are healthy and synced."
  return 0
}

check_galera_pod_ready() {
  local pod=$1
  local namespace=$2
  local expected_size=${3:-5}

  get_mariadb_env_vars "$pod"

  # Check if MySQL is ready
  if ! oc exec -n "$namespace" "$pod" -- mysqladmin -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" ping --silent 2>/dev/null | grep -q "mysqld is alive"; then
    echo "$pod: MySQL is not ready yet."
    return 1
  fi

  get_mariadb_env_vars "$pod"

  local status_output
  status_output=$(oc exec -n "$namespace" "$pod" -- \
    mysql -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS LIKE 'wsrep_%';" 2>/dev/null)

  local cluster_status
  cluster_status=$(echo "$status_output" | awk '/wsrep_cluster_status/ {print $2}')
  local local_state
  local_state=$(echo "$status_output" | awk '/wsrep_local_state_comment/ {print $2}')
  local cluster_size
  cluster_size=$(echo "$status_output" | awk '/wsrep_cluster_size/ {print $2}')

  echo "$pod: cluster_status=$cluster_status, local_state=$local_state, cluster_size=$cluster_size (of expected: $expected_size)"

  if [[ "$cluster_status" == "Primary" && "$local_state" == "Synced" && "$cluster_size" == "$expected_size" ]]; then
    return 0
  fi

  # If pod is Disconnected or in non-primary, restart it
  if [[ "$cluster_status" == "Disconnected" || "$cluster_status" == "non-primary" ]]; then
    echo "$pod: Detected Disconnected/non-primary state, restarting pod..."
    delete_pod "$pod"
    return 1
  fi

  return 1
}

wait_for_redis_sync() {
  local redis_name=$1
  local namespace=$2
  local max_retries=${3:-30}
  local wait_time=${4:-10}
  local retry_count=0

  echo "Waiting for Redis nodes to sync (checking logs for 'Background AOF rewrite finished successfully')..."

  while true; do
    local all_synced=true

    # Get the list of Redis pods
    local pods=$(oc get pods -n $namespace --selector=statefulset=$redis_name -o jsonpath='{.items[*].metadata.name}')

    for pod in $pods; do
      # Fetch the logs for the current pod
      local logs=$(oc logs $pod -n $namespace 2>&1)

      # Check if the required message is present in the logs
      if ! echo "$logs" | grep -q "Background AOF rewrite finished successfully"; then
        echo "Pod $pod is not yet synced. Retrying..."
        all_synced=false
        break
      fi
    done

    if $all_synced; then
      echo "✔️ All Redis nodes are synced and ready."
      return 0
    fi

    # Retry logic
    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Timeout waiting for Redis nodes to sync. Exiting..."
      return 1
    fi

    sleep $wait_time
  done
}

test_redis_proxy_connectivity() {
  local pod=$1
  local namespace=$2
  local error_patterns="err:,panic,fatal"

  echo "Testing Redis Proxy connectivity from pod: $pod"

  # 1. Check PING
  if oc exec -n "$namespace" "$pod" -- redis-cli -h localhost -p 6379 PING | grep -q "PONG"; then
    echo "✔️ Pod $pod is responding to PING."
  else
    echo "❌ Pod $pod is not responding to PING."
    return 1
  fi

  # 2. Check logs for error patterns
  if check_logs_for_pattern "$pod" "$namespace" "$error_patterns"; then
    echo "❌ Pod $pod logs contain error patterns."
    delete_pod "$pod"
    # Wait for the new pod to be ready
    echo "Waiting for new pod to be ready after deletion..."
    oc wait --for=condition=Ready pod -l app=redis-proxy -n "$namespace" --timeout=180s
    return 1
  fi

  echo "✔️ No errors found in pod: $pod"

  return 0
}

wait_for_redis_proxy_ready() {
  local redis_proxy_name=$1
  local namespace=$2
  local max_retries=${3:-30}
  local wait_time=${4:-10}
  local retry_count=0

  echo "Waiting for all Redis Proxy pods to be ready and functional..."

  while true; do
    # Use handle_pods_in_resource to process all Redis Proxy pods
    if handle_pods_in_resource "$redis_proxy_name" "$namespace" test_redis_proxy_connectivity $max_retries $wait_time; then
      echo "✔️ All Redis Proxy pods are ready and functional."
      return 0
    fi

    # Retry logic for the entire set of pods
    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Timeout waiting for all Redis Proxy pods to be ready and functional. Exiting..."
      return 1
    fi

    echo "Retrying in $wait_time seconds... (Attempt $retry_count/$max_retries)"
    sleep $wait_time
  done
}

handle_pods_in_resource() {
  local resource_name=$1
  local namespace=$2
  local action=$3
  local error_search_string=$4
  local error_handler=$5
  local max_retries=${6:-30}
  local wait_time=${7:-10}
  local retry_count=0

  # echo "Handling pods for resource: $resource_name in namespace: $namespace"

  while true; do
    local pods
    pods=$(get_pods_for_resource "$resource_name" "$namespace")
    local status=$?

    if [[ $status -ne 0 ]]; then
      echo "❌ Failed to retrieve pods for resource: $resource_name. Exiting..."
      return 1
    fi

    if [[ -z "$pods" ]]; then
      echo "❌ No pods found for resource: $resource_name. Exiting..."
      return 1
    fi

    local all_pods_handled=true

    for pod in $pods; do
      # echo "Handle Processing pod: $pod"

      if ! oc wait --for=condition=ready pod/$pod -n $namespace --timeout=10s &> /dev/null; then
        echo "Pod $pod is not ready. Retrying..."
        all_pods_handled=false
        continue
      fi

      # Call action with pod, namespace, and additional arguments explicitly
      if ! "$action" "$pod" "$namespace" "$error_search_string" "$error_handler"; then
        echo "❌ Action failed for pod: $pod"
        echo "Action: $action"
        # echo "Arguments: $pod $namespace $error_search_string $error_handler"
        echo "Retrying..."
        all_pods_handled=false
        continue
      fi

      if ! oc get pod $pod -n $namespace &> /dev/null; then
        echo "❌ Pod $pod has been deleted. Moving to the next pod..."
        all_pods_handled=false
        continue
      fi
    done

    if $all_pods_handled; then
      echo "✔️ All pods for resource: $resource_name have been successfully handled."
      return 0
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Timeout waiting for all pods in resource: $resource_name to be handled. Exiting..."
      return 1
    fi

    echo "Retrying in $wait_time seconds..."
    sleep $wait_time
  done
}

get_pods_for_resource() {
  local resource_name=$1
  local namespace=$2
  local resource_type=""

  # Debug information
  # echo "DEBUG: get_pods_for_resource called with resource_name='$resource_name', namespace='$namespace'" >&2

  if [[ "$resource_name" == */* ]]; then
    resource_type=${resource_name%%/*}
    resource_name=${resource_name##*/}
    # echo "DEBUG: Extracted resource_type='$resource_type', resource_name='$resource_name'" >&2

    # Handle full API resource names (e.g., deployment.apps -> deployment)
    case "$resource_type" in
      "deployment.apps" | "deployments.apps") resource_type="deployment" ;;
      "statefulset.apps" | "statefulsets.apps") resource_type="statefulset" ;;
      "service.v1" | "services.v1") resource_type="service" ;;
      "job.batch" | "jobs.batch") resource_type="job" ;;
    esac
    # echo "DEBUG: Normalized resource_type='$resource_type'" >&2
  fi

  # Debug platform detection
  # echo "DEBUG: Checking platform - Docker available: $(command -v docker >/dev/null 2>&1 && echo 'yes' || echo 'no')" >&2
  # echo "DEBUG: Checking platform - OpenShift available: $(command -v oc >/dev/null 2>&1 && echo 'yes' || echo 'no')" >&2
  # echo "DEBUG: Checking platform - oc whoami works: $(oc whoami >/dev/null 2>&1 && echo 'yes' || echo 'no')" >&2

  # Prioritize OpenShift detection - if oc is available and we can authenticate, use OpenShift
  if is_openshift; then
    # echo "DEBUG: Using OpenShift platform" >&2
    if [[ -z "$resource_type" ]]; then
      if oc get statefulset "$resource_name" -n "$namespace" &> /dev/null; then
        resource_type="statefulset"
      elif oc get deployment "$resource_name" -n "$namespace" &> /dev/null; then
        resource_type="deployment"
      else
        echo "❌ Resource $resource_name not found in namespace $namespace. Exiting..." >&2
        return 1
      fi
    else
      # Validate that the provided resource type is supported and exists
      if [[ "$resource_type" != "statefulset" && "$resource_type" != "deployment" && "$resource_type" != "sts" && "$resource_type" != "deploy" && "$resource_type" != "service" && "$resource_type" != "job" ]]; then
        echo "❌ Unsupported resource type: $resource_type. Supported types: statefulset, deployment, sts, deploy, service, job" >&2
        return 1
      fi
      # Normalize resource type
      case "$resource_type" in
        "sts") resource_type="statefulset" ;;
        "deploy") resource_type="deployment" ;;
      esac
      # echo "DEBUG: Final normalized resource_type='$resource_type'" >&2
      # Verify the resource actually exists
      if ! oc get "$resource_type" "$resource_name" -n "$namespace" &> /dev/null; then
        echo "❌ Resource $resource_type/$resource_name not found in namespace $namespace. Exiting..." >&2
        return 1
      fi
    fi
  elif is_docker; then
    # echo "DEBUG: Using Docker platform" >&2
    # For Docker, assume container names include the resource name as a substring
    local containers=$(docker ps --filter "name=$resource_name" --filter "status=running" --format '{{.Names}}')
    # echo "DEBUG: Found Docker containers: '$containers'" >&2
    echo "$containers"
    return 0
  else
    echo "ERROR: Unknown platform (neither OpenShift nor Docker detected)"
    return 1
  fi

  echo "Getting pods for: $resource_type / $resource_name" >&2

  local pods=""
  if [[ "$resource_type" == "statefulset" ]]; then
    # echo "DEBUG: Processing as statefulset" >&2
    # Try common label selectors for Helm/Operator-managed statefulsets
    pods=$(oc get pods -n "$namespace" -l "app.kubernetes.io/name=$resource_name" -o jsonpath='{.items[*].metadata.name}')
    if [[ -z "$pods" ]]; then
      pods=$(oc get pods -n "$namespace" -l "app.kubernetes.io/instance=$resource_name" -o jsonpath='{.items[*].metadata.name}')
    fi
    # Fallback: match pod names by prefix
    if [[ -z "$pods" ]]; then
      pods=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "^${resource_name}-")
    fi
  else
    # For deployments, use the label selector as before
    # echo "DEBUG: Processing as deployment/other resource type" >&2
    # Ensure resource_type is not empty to avoid "server doesn't have a resource type" error
    if [[ -z "$resource_type" ]]; then
      echo "❌ Resource type could not be determined for $resource_name in namespace $namespace" >&2
      return 1
    fi

    local labels=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels}')
    # echo "DEBUG: Raw labels from deployment: '$labels'" >&2

    local label_selector
    label_selector=$(oc get "$resource_type" "$resource_name" -n "$namespace" \
      -o jsonpath="{.spec.selector.matchLabels['app.kubernetes.io/name']}")
    # echo "DEBUG: app.kubernetes.io/name label: '$label_selector'" >&2

    if [[ -n "$label_selector" ]]; then
      label_selector="app.kubernetes.io/name=$label_selector"
    else
      label_selector=$(echo "$labels" | tr -d '{}"' | sed 's/[:=]/=/g')
    fi
    # echo "DEBUG: Final label selector: '$label_selector'" >&2

    if [[ -z "$label_selector" || "$label_selector" == "=" ]]; then
      # echo "DEBUG: No valid label selector found, falling back to deployment name matching" >&2
      # Fallback: get pods that are owned by this deployment's replicaset
      local replicasets=$(oc get replicaset -n "$namespace" -l "app=$resource_name" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      if [[ -n "$replicasets" ]]; then
        for rs in $replicasets; do
          local rs_pods=$(oc get pods -n "$namespace" -l "pod-template-hash" --field-selector="metadata.ownerReferences[0].name=$rs" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
          pods="$pods $rs_pods"
        done
      fi
      # Another fallback: match by deployment name prefix
      if [[ -z "$pods" ]]; then
        pods=$(oc get pods -n "$namespace" -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "^${resource_name}-" | tr '\n' ' ')
      fi
    else
      pods=$(oc get pods -n "$namespace" --selector="$label_selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
    fi
    # echo "DEBUG: Found pods: '$pods'" >&2
  fi

  # Clean up any extra spaces and filter out empty results
  pods=$(echo "$pods" | xargs)
  # echo "DEBUG: Final cleaned pods: '$pods'" >&2

  if [[ -z "$pods" ]]; then
    echo "No pods found for resource: $resource_name." >&2
    echo ""
    return 0
  fi

  echo "$pods"
  return 0
}

generate_sentinel_config_json() {
  local namespace="$1"
  local redis_sts_name="$2"
  local headless_service="$3"
  local port="${4:-26379}"
  local output_file="${5:-sentinel_tunnel.remote.config.json}"

  # Get the number of replicas from the StatefulSet
  local replicas
  replicas=$(oc get statefulset "$redis_sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}')
  if [[ -z "$replicas" ]]; then
    echo "Could not determine replica count for $redis_sts_name in $namespace"
    return 1
  fi

  # Build the sentinels list
  local sentinels=()
  for i in $(seq 0 $((replicas-1))); do
    sentinels+=("\"${redis_sts_name}-$i.${headless_service}.${namespace}.svc.cluster.local:${port}\"")
  done
  local sentinels_joined
  sentinels_joined=$(IFS=, ; echo "${sentinels[*]}")

  # Output the JSON
  cat <<EOF > "$output_file"
{
  "Sentinels_addresses_list":[
    $sentinels_joined
  ],
	"Databases":[
		{
			"Name": "mymaster",
			"Local_port": "6379"
		}
	]
}
EOF
}

should_migrate_by_version() {
  local src_version_file="/app/public/version.php"
  local dest_version_file="/var/www/html/version.php"

  if [[ ! -f "$src_version_file" ]]; then
    echo "Source version file not found: $src_version_file"
    echo "Migration cannot proceed."
    return 1  # Fail if source is missing
  fi
  if [[ ! -f "$dest_version_file" ]]; then
    echo "Destination version file not found: $dest_version_file"
    return 0  # Proceed with migration if destination is missing
  fi

  # Extract version numbers using grep and sed
  local src_version
  local dest_version
  src_version=$(grep -Eo '\$version\s*=\s*[0-9]+\.[0-9]+' "$src_version_file" | sed -E 's/[^0-9.]+//g')
  dest_version=$(grep -Eo '\$version\s*=\s*[0-9]+\.[0-9]+' "$dest_version_file" | sed -E 's/[^0-9.]+//g')

  if [[ -z "$src_version" || -z "$dest_version" ]]; then
    echo "Could not extract version from one or both files."
    return 0  # Proceed with migration if extraction fails
  fi

  echo "Source version: $src_version"
  echo "Destination version: $dest_version"

  if [[ "$src_version" == "$dest_version" ]]; then
    return 1  # Skip migration
  else
    return 0  # Proceed with migration
  fi
}

get_mariadb_env_vars() {
  local pod_name="$1"

  # Prioritize OpenShift detection - if oc is available and we can authenticate, use OpenShift
  if is_openshift; then
    # Get the environment variables from the pod
    MARIADB_USER=$(oc exec -n "$DEPLOY_NAMESPACE" "$pod_name" -- printenv MARIADB_USER)
    MARIADB_PASSWORD_FILE=$(oc exec -n "$DEPLOY_NAMESPACE" "$pod_name" -- printenv MARIADB_PASSWORD_FILE)
    MARIADB_PASSWORD=$(oc exec -n "$DEPLOY_NAMESPACE" "$pod_name" -- cat "$MARIADB_PASSWORD_FILE")
    MARIADB_DATABASE=$(oc exec -n "$DEPLOY_NAMESPACE" "$pod_name" -- printenv MARIADB_DATABASE)
  elif is_docker; then
    # For Docker, assume container names include the resource name as a substring
    MARIADB_USER=$(docker exec "$pod_name" printenv MARIADB_USER)
    MARIADB_PASSWORD_FILE=$(docker exec "$pod_name" printenv MARIADB_PASSWORD_FILE)
    MARIADB_PASSWORD=$(docker exec "$pod_name" cat "$MARIADB_PASSWORD_FILE")
    MARIADB_DATABASE=$(docker exec "$pod_name" printenv MARIADB_DATABASE)
  else
    echo "ERROR: Unknown platform (neither OpenShift nor Docker detected)"
    return 1
  fi

  return 0
}


find_db_characters() {
  local table="$1"
  local column="$2"
  local csv_file="/usr/local/bin/includes/mojibake_replacements_2.csv"
  local pod_name="${3:-db-0}"

  # Validate inputs
  if [[ -z "$pod_name" ]]; then
    echo "Pod name is required."
    return 1
  fi
  if [[ -z "$table" || -z "$column" ]]; then
    echo "Table and column names are required."
    return 1
  fi
  if [[ ! -f "$csv_file" ]]; then
    echo "CSV file not found: $csv_file"
    return 1
  fi

  # Use get_pods_for_resource to get the first MariaDB pod
  local db_pods db_pod
  db_pods=$(get_pods_for_resource "$pod_name" "$DEPLOY_NAMESPACE")
  db_pod=$(echo "$db_pods" | awk '{print $1}')
  if [[ -z "$db_pod" ]]; then
    echo "Could not find a mariadb-galera pod."
    return 1
  fi

  # Build regex from CSV
  local regex
  regex=$(read_csv_file "$csv_file" | awk '{printf "%s|", $1}' | sed 's/|$//')

  # Get the database credentials from the pod
  get_mariadb_env_vars "$pod_name"

  local sql="USE \`$MARIADB_DATABASE\`; SELECT \`id\`, \`${column}\` FROM \`${table}\` WHERE \`${column}\` REGEXP '${regex}';"
  oc exec -n "$DEPLOY_NAMESPACE" "$db_pod" -- \
    mysql -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "$sql"
}

replace_db_characters_from_csv() {
  local table="$1"
  local column="$2"
  local csv_file="/usr/local/bin/includes/mojibake_replacements_2.csv"

  # Use get_pods_for_resource to get the first MariaDB pod
  local db_pods db_pod
  db_pods=$(get_pods_for_resource "mariadb-galera" "$DEPLOY_NAMESPACE")
  db_pod=$(echo "$db_pods" | awk '{print $1}')
  if [[ -z "$db_pod" ]]; then
    echo "Could not find a mariadb-galera pod."
    return 1
  fi

  get_mariadb_env_vars "$db_pod"

  read_csv_file "$csv_file" | while IFS=$'\t' read -r garbled intended; do
    # Escape single quotes for SQL
    local garbled_esc intended_esc
    garbled_esc=$(printf "%s" "$garbled" | sed "s/'/''/g")
    intended_esc=$(printf "%s" "$intended" | sed "s/'/''/g")
    local sql="USE \`$MARIADB_DATABASE\`; UPDATE \`${table}\` SET \`${column}\` = REPLACE(\`${column}\`, '${garbled_esc}', '${intended_esc}');"
    echo "Replacing '$garbled' with '$intended' in $table.$column"
    oc exec -n "$DEPLOY_NAMESPACE" "$db_pod" -- \
      mysql -u"$MARIADB_USER" -p"$MARIADB_PASSWORD" "$MARIADB_DATABASE" -e "$sql"
  done
}

read_csv_file() {
  local csv_file="$1"
  local col_1="${2:-1}"
  local col_2="${3:-2}"

  # Skip header, output tab-separated pairs: garbled<TAB>intended
  awk -F',' -v gc="$col_1" -v ic="$col_2" 'NR>1 {print $gc "\t" $ic}' "$csv_file"
}

process_moodle_content_columns() {
  local action_func="$1"  # e.g., find_db_characters or replace_db_characters_from_csv
  local columns_csv="/scripts/content_replacement_columns.csv"

  # Skip header, then for each line call the action function
  tail -n +2 "$columns_csv" | while IFS=',' read -r table column; do
    # Trim whitespace and carriage returns
    table=$(echo "$table" | tr -d '\r' | xargs)
    column=$(echo "$column" | tr -d '\r' | xargs)
    if [[ -n "$table" && -n "$column" ]]; then
      echo "Processing $table.$column ..."
      "$action_func" "$table" "$column"
    fi
  done
}

moodle_content_cleanup() {
  local mode="$1" # "find" or "replace"
  if [[ "$mode" == "find" ]]; then
    process_moodle_content_columns find_db_characters
  elif [[ "$mode" == "replace" ]]; then
    process_moodle_content_columns replace_db_characters_from_csv
  else
    echo "Unknown mode: $mode"
    return 1
  fi
}

# Find courses with a given tag
find_courses_with_tag() {
  local tag="$1"
  local namespace="$2"
  local cron_pod
  cron_pod=$(oc get pods -n "$namespace" -l app=cron -o jsonpath='{.items[0].metadata.name}')
  oc exec -n "$namespace" "$cron_pod" -- php /var/www/html/migrate-courses/find-courses-with-tag.php "$tag"
}

# Backup a course by ID
backup_course() {
  local courseid="$1"
  local namespace="$2"
  local cron_pod
  cron_pod=$(oc get pods -n "$namespace" -l app=cron -o jsonpath='{.items[0].metadata.name}')
  oc exec -n "$namespace" "$cron_pod" -- php /var/www/html/admin/cli/backup.php --courseid="$courseid" --destination="/tmp/file-backups/transfer"
}

copy_backup_out() {
  local namespace="$1"
  local pod_or_container="$2"
  local file="$3"
  local local_dest="$4"

  # echo "DEBUG: [copy_backup_out] namespace='$namespace'"
  # echo "DEBUG: [copy_backup_out] pod_or_container='$pod_or_container'"
  # echo "DEBUG: [copy_backup_out] file='$file'"
  # echo "DEBUG: [copy_backup_out] local_dest='$local_dest'"

  # Check if all required parameters are set
  if [[ -z "$namespace" || -z "$cron_pod" || -z "$file" || -z "$local_dest" ]]; then
    echo "ERROR: One or more required parameters are empty in copy_backup_out!"
    return 1
  fi

  # Check if the file exists in the pod before copying
  # echo "DEBUG: [copy_backup_out] Checking if file exists in pod..."
  oc exec -n "$namespace" "$cron_pod" -- ls -l "$file"

  platform_cp "$namespace/$pod_or_container:$file" "$local_dest" "$namespace"
  platform_exec "$namespace" "$pod_or_container" rm -f "$file"
}

copy_backup_in() {
  local namespace="$1"
  local pod_or_container="$2"
  local local_file="$3"
  local pod_dest="$4"

  # echo "DEBUG: [copy_backup_in] namespace='$namespace'"
  # echo "DEBUG: [copy_backup_in] pod_or_container='$pod_or_container'"
  # echo "DEBUG: [copy_backup_in] local_file='$local_file'"
  # echo "DEBUG: [copy_backup_in] pod_dest='$pod_dest'"

  if [[ -z "$namespace" || -z "$pod_or_container" || -z "$local_file" || -z "$pod_dest" ]]; then
    echo "ERROR: One or more required parameters are empty in copy_backup_in!"
    return 1
  fi

  # oc cp "$local_file" "$namespace/$pod_or_container:$pod_dest"
  platform_cp "$local_file" "$namespace/$pod_or_container:$pod_dest" "$namespace"
}

cleanup_old_backups() {
  local namespace="$1"
  local cron_pod="$2"
  oc exec -n "$namespace" "$cron_pod" -- bash -c '
    cd /tmp/file-backups/transfer
    for course in $(ls backup-moodle2-course-*-*.mbz 2>/dev/null | sed "s/backup-moodle2-course-\([0-9]*\)-.*/\1/" | sort -u); do
      ls -t backup-moodle2-course-${course}-*.mbz | tail -n +2 | xargs -r rm --
    done
  '
}

# Update course tag
update_course_tag() {
  local courseid="$1"
  local newtag="$2"
  local namespace="$3"
  local cron_pod
  cron_pod=$(oc get pods -n "$namespace" -l app=cron -o jsonpath='{.items[0].metadata.name}')
  oc exec -n "$namespace" "$cron_pod" -- php /var/www/html/migrate-courses/update-course-tag.php "$courseid" "$newtag"
}

is_openshift() {
  command -v oc >/dev/null 2>&1 && oc whoami >/dev/null 2>&1
}

is_docker() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

platform_exec() {
  local namespace="$1"
  local pod_or_container="$2"
  shift 2
  # Prioritize OpenShift detection
  if is_openshift; then
    oc exec -n "$namespace" "$pod_or_container" -- "$@"
  elif is_docker; then
    docker exec "$pod_or_container" "$@"
  else
    echo "ERROR: Unknown platform (neither OpenShift nor Docker detected)"
    return 1
  fi
}

platform_cp() {
  local src="$1"
  local dest="$2"
  local namespace="$3"
  # Prioritize OpenShift detection
  if is_openshift; then
    # src or dest may be pod:filepath
    echo "Copying from $src to $dest using OpenShift..."
    oc cp "$src" "$dest" -n "$namespace"
  elif is_docker; then
    echo "Copying from $src to $dest using Docker..."
    docker cp "$src" "$dest"
  else
    echo "ERROR: Unknown platform (neither OpenShift nor Docker detected)"
    return 1
  fi
}

# Function to remove problematic Redis startup probe
remove_redis_startup_probe() {
  local statefulset_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  echo "🔧 Checking for problematic startup probes..."

  # Check if startup probes exist on both containers
  local redis_startup_probe
  local sentinel_startup_probe
  redis_startup_probe=$(oc get statefulset "$statefulset_name" -n "$namespace" -o jsonpath='{.spec.template.spec.containers[0].startupProbe}' 2>/dev/null)
  sentinel_startup_probe=$(oc get statefulset "$statefulset_name" -n "$namespace" -o jsonpath='{.spec.template.spec.containers[1].startupProbe}' 2>/dev/null)

  local patches=()
  local patch_needed=false

  # Check Redis container startup probe
  if [[ -n "$redis_startup_probe" && "$redis_startup_probe" != "null" ]]; then
    echo "⚠️  Found problematic startup probe on Redis container"
    patches+=('{"op": "remove", "path": "/spec/template/spec/containers/0/startupProbe"}')
    patch_needed=true
  fi

  # Check Sentinel container startup probe
  if [[ -n "$sentinel_startup_probe" && "$sentinel_startup_probe" != "null" ]]; then
    echo "⚠️  Found problematic startup probe on Sentinel container"
    patches+=('{"op": "remove", "path": "/spec/template/spec/containers/1/startupProbe"}')
    patch_needed=true
  fi

  if [[ "$patch_needed" == "true" ]]; then
    # Create the JSON patch array
    local patch_content="["
    for i in "${!patches[@]}"; do
      if [[ $i -gt 0 ]]; then
        patch_content+=","
      fi
      patch_content+="${patches[$i]}"
    done
    patch_content+="]"

    # Use generic apply_resource_patch function
    if apply_resource_patch "statefulset" "$statefulset_name" "$patch_content" "$namespace" "Removing problematic startup probes"; then
      echo "✅ Successfully removed problematic startup probes"
      return 0
    else
      echo "⚠️  Warning: Failed to remove startup probes"
      return 1
    fi
  else
    echo "✅ No problematic startup probes found"
    return 0
  fi
}

# Generic function to fix container probe timing and commands
fix_container_probes() {
  local statefulset_name="$1"
  local container_index="$2"
  local container_name="$3"
  local liveness_script="$4"
  local readiness_script="$5"
  local namespace="${6:-$DEPLOY_NAMESPACE}"
  local initial_delay="${7:-180}"
  local timeout="${8:-10}"
  local period="${9:-10}"
  local failure_threshold="${10:-5}"

  echo "🔧 Updating $container_name container probe configurations (${initial_delay}s delay)..."

  # Create a comprehensive patch to fix both liveness and readiness probes
  local patch_content='[
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/'${container_index}'/livenessProbe",
    "value": {
      "exec": {
        "command": [
          "/bin/bash",
          "-c",
          "'${liveness_script}'"
        ]
      },
      "initialDelaySeconds": '${initial_delay}',
      "timeoutSeconds": '${timeout}',
      "periodSeconds": '${period}',
      "failureThreshold": '${failure_threshold}',
      "successThreshold": 1
    }
  },
  {
    "op": "replace",
    "path": "/spec/template/spec/containers/'${container_index}'/readinessProbe",
    "value": {
      "exec": {
        "command": [
          "/bin/bash",
          "-c",
          "'${readiness_script}'"
        ]
      },
      "initialDelaySeconds": '${initial_delay}',
      "timeoutSeconds": '${timeout}',
      "periodSeconds": '${period}',
      "failureThreshold": '${failure_threshold}',
      "successThreshold": 1
    }
  }
]'

  # Use generic apply_resource_patch function
  if apply_resource_patch "statefulset" "$statefulset_name" "$patch_content" "$namespace" "Updating $container_name container probe configurations"; then
    echo "✅ Successfully updated $container_name container probe configurations"

    # Verify the probes were updated using verify_patch_result
    local verification_checks="{.spec.template.spec.containers[${container_index}].livenessProbe.initialDelaySeconds}:${initial_delay},{.spec.template.spec.containers[${container_index}].readinessProbe.initialDelaySeconds}:${initial_delay}"
    if verify_patch_result "statefulset" "$statefulset_name" "$verification_checks" "$namespace"; then
      echo "✅ Verified: $container_name probes updated with ${initial_delay}s delay"
    else
      echo "⚠️  Warning: $container_name probe verification failed"
    fi

    return 0
  else
    echo "⚠️  Warning: Failed to update $container_name container probes"
    return 1
  fi
}

# Function to fix Redis container probe timing and commands
fix_redis_container_probes() {
  local statefulset_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local initial_delay="${3:-180}"
  local timeout="${4:-10}"
  local period="${5:-10}"
  local failure_threshold="${6:-5}"

  # Use the generic function with Redis-specific parameters
  fix_container_probes "$statefulset_name" "0" "Redis" "/health/ping_liveness_local.sh 5" "/health/ping_readiness_local.sh 1" "$namespace" "$initial_delay" "$timeout" "$period" "$failure_threshold"
}

# Function to fix Sentinel container probe timing and commands
fix_sentinel_container_probes() {
  local statefulset_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local initial_delay="${3:-180}"
  local timeout="${4:-10}"
  local period="${5:-10}"
  local failure_threshold="${6:-5}"

  # Use the generic function with Sentinel-specific parameters
  fix_container_probes "$statefulset_name" "1" "Sentinel" "/health/ping_sentinel.sh 10" "/health/ping_sentinel.sh 10" "$namespace" "$initial_delay" "$timeout" "$period" "$failure_threshold"
}

# Combined function to apply all Redis probe fixes
apply_redis_probe_fixes() {
  local statefulset_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local initial_delay="${3:-180}"

  echo "🔧 Applying Redis probe fixes to $statefulset_name..."

  # Remove startup probe first
  remove_redis_startup_probe "$statefulset_name" "$namespace"

  # Fix liveness and readiness probes for both Redis and Sentinel containers
  fix_redis_container_probes "$statefulset_name" "$namespace" "$initial_delay"
  fix_sentinel_container_probes "$statefulset_name" "$namespace" "$initial_delay"

  echo "✅ Redis probe fixes completed"
}

# Moodle cache management function with dynamic path detection
moodle_cache_purge() {
  local web_root="${1:-/var/www/html}"
  local data_root="${2:-}"  # Will be auto-detected if not provided
  local theme_name="${3:-bcgovpsa}"
  local verbose="${4:-false}"

  echo "🧹 Starting robust Moodle cache purge..."

  # Auto-detect Moodle data root and cache directories from config
  if [[ -z "$data_root" ]]; then
    echo "🔍 Auto-detecting Moodle cache directories from config..."
    data_root=$(get_moodle_config_value "dataroot" "$web_root")
    if [[ -z "$data_root" ]]; then
      echo "⚠️  Could not detect dataroot from config, using default: /var/www/moodledata"
      data_root="/var/www/moodledata"
    else
      echo "✅ Detected dataroot: $data_root"
    fi
  fi

  # Get all cache-related directories from Moodle config
  local cache_dirs=()
  local filecache_dir cachedir_dir tempdir_dir localrequest_dir backuptemp_dir

  filecache_dir=$(get_moodle_config_value "filecache" "$web_root")
  cachedir_dir=$(get_moodle_config_value "cachedir" "$web_root")
  tempdir_dir=$(get_moodle_config_value "tempdir" "$web_root")
  localrequest_dir=$(get_moodle_config_value "localrequestdir" "$web_root")
  backuptemp_dir=$(get_moodle_config_value "backuptempdir" "$web_root")

  # Add default dataroot cache if no specific dirs found
  cache_dirs+=("$data_root/cache")
  cache_dirs+=("$data_root/localcache")

  # Add configured cache directories if they exist
  [[ -n "$filecache_dir" ]] && cache_dirs+=("$filecache_dir")
  [[ -n "$cachedir_dir" ]] && cache_dirs+=("$cachedir_dir")
  [[ -n "$tempdir_dir" ]] && cache_dirs+=("$tempdir_dir")
  [[ -n "$localrequest_dir" ]] && cache_dirs+=("$localrequest_dir")
  [[ -n "$backuptemp_dir" ]] && cache_dirs+=("$backuptemp_dir")

  echo "📁 Cache directories to process: ${#cache_dirs[@]}"
  for dir in "${cache_dirs[@]}"; do
    echo "   - $dir"
  done

  # Add verbose flag if requested
  local verbose_flag=""
  if [[ "$verbose" == "true" ]]; then
    verbose_flag="--verbose"
  fi

  # Function to debug cache state
  debug_cache_state() {
    local stage="$1"
    echo "=== Cache Debug - $stage ==="

    for cache_dir in "${cache_dirs[@]}"; do
      if [[ -d "$cache_dir" ]]; then
        echo "📁 Cache directory: $cache_dir"
        local file_count
        file_count=$(find "$cache_dir" -type f 2>/dev/null | wc -l)
        echo "📊 Files in $cache_dir: $file_count"
        ls -la "$cache_dir/" 2>/dev/null | head -3
      else
        echo "❌ Cache directory not found: $cache_dir"
      fi
    done

    echo "👤 Current user: $(whoami) ($(id -u):$(id -g))"
  }

  # Step 1: Debug initial state
  if [[ "$verbose" == "true" ]]; then
    debug_cache_state "BEFORE"
  fi

  # Step 2: Standard Moodle cache purge
  echo "🔄 Step 1: Standard Moodle cache purge..."
  if php "$web_root/admin/cli/purge_caches.php" $verbose_flag; then
    echo "✅ Standard cache purge completed"
  else
    echo "⚠️  Standard cache purge had issues"
  fi

  # Step 3: Manual cache directory cleanup
  echo "🗑️  Step 2: Manual cache cleanup for all configured directories..."
  for cache_dir in "${cache_dirs[@]}"; do
    if [[ -d "$cache_dir" ]]; then
      echo "🧹 Cleaning cache directory: $cache_dir"
      # Clear various cache file types
      find "$cache_dir" -type f -name "*.cache" -delete 2>/dev/null || true
      find "$cache_dir" -type f -name "*.lock" -delete 2>/dev/null || true
      find "$cache_dir" -type f -name "*.tmp" -delete 2>/dev/null || true

      # Clear theme cache specifically if it exists in this directory
      if [[ -d "$cache_dir/theme" ]]; then
        echo "🎨 Clearing theme cache in: $cache_dir/theme"
        rm -rf "$cache_dir/theme"/* 2>/dev/null || true
      fi

      # Clear other common cache subdirectories
      for cache_subdir in "cachestore_file" "htmlpurifier" "lang" "javascript" "scss"; do
        if [[ -d "$cache_dir/$cache_subdir" ]]; then
          echo "🧹 Clearing $cache_subdir cache in: $cache_dir"
          rm -rf "$cache_dir/$cache_subdir"/* 2>/dev/null || true
        fi
      done
    else
      echo "⚠️  Cache directory not accessible: $cache_dir"
    fi
  done

  # Step 4: Rebuild theme cache
  echo "🎨 Step 3: Rebuilding theme cache..."
  if php "$web_root/admin/cli/build_theme_css.php" --themes="$theme_name" $verbose_flag; then
    echo "✅ Theme cache rebuild completed"
  else
    echo "⚠️  Theme cache rebuild had issues"
  fi

  # Step 5: Final cache purge
  echo "🔄 Step 4: Final cache purge..."
  php "$web_root/admin/cli/purge_caches.php" 2>/dev/null || true

  # Step 6: Fix permissions for all cache directories
  echo "🔐 Step 5: Setting cache permissions..."
  for cache_dir in "${cache_dirs[@]}"; do
    if [[ -d "$cache_dir" ]]; then
      echo "🔐 Setting permissions for: $cache_dir"
      if command -v chown >/dev/null 2>&1; then
        chown -R www-data:www-data "$cache_dir/" 2>/dev/null || true
        chmod -R 755 "$cache_dir/" 2>/dev/null || true
      fi
    fi
  done

  # Step 7: Verification
  if [[ "$verbose" == "true" ]]; then
    debug_cache_state "AFTER"

    # Verify theme cache was rebuilt in any of the cache directories
    local theme_files_found=false
    for cache_dir in "${cache_dirs[@]}"; do
      if [[ -d "$cache_dir/theme" ]]; then
        local theme_files
        theme_files=$(find "$cache_dir/theme" -type f 2>/dev/null | wc -l)
        if [[ $theme_files -gt 0 ]]; then
          echo "✅ Theme cache verification: $theme_files files found in $cache_dir/theme"
          theme_files_found=true
        fi
      fi
    done

    if [[ "$theme_files_found" == "false" ]]; then
      echo "⚠️  WARNING: No theme cache files found in any cache directory after rebuild!"
      return 1
    fi
  fi

  echo "✅ Robust Moodle cache purge completed"
  return 0
}

# Helper function to extract Moodle config values
get_moodle_config_value() {
  local config_key="$1"
  local web_root="${2:-/var/www/html}"
  local config_file="$web_root/config.php"

  if [[ ! -f "$config_file" ]]; then
    echo ""
    return 1
  fi

  # Extract the config value using grep and sed
  # This handles both quoted strings and variables
  local value
  value=$(grep -E "^\s*\\\$CFG->$config_key\s*=" "$config_file" | head -1 | sed -E "s/.*=\s*['\"]?([^'\";\s]+)['\"]?\s*;.*/\1/")

  # Handle variable references like $_SERVER['VARIABLE']
  if [[ "$value" =~ ^\$_SERVER\[.*\] ]]; then
    # For server variables, we can't easily resolve them, return empty
    echo ""
    return 1
  fi

  echo "$value"
}

# Function to clear Moodle cache on a single pod
clear_cache_on_pod() {
  local pod_name="$1"
  local namespace="$2"
  local theme_name="${3:-bcgovpsa}"

  echo "🧹 Clearing cache on pod: $pod_name"

  # Step 1: Purge cache
  echo "🔄 Purging cache..."
  if ! oc exec -n "$namespace" "$pod_name" --timeout=300s -- php /var/www/html/admin/cli/purge_caches.php; then
    echo "❌ Cache purge failed on $pod_name"
    return 1
  fi

  # Step 2: Rebuild theme cache
  echo "🎨 Rebuilding theme cache..."
  if ! oc exec -n "$namespace" "$pod_name" --timeout=300s -- php /var/www/html/admin/cli/build_theme_css.php --themes="$theme_name"; then
    echo "⚠️  Theme rebuild failed on $pod_name (not critical)"
  fi

  # Step 3: Final cache purge
  echo "🔄 Final cache purge..."
  oc exec -n "$namespace" "$pod_name" --timeout=300s -- php /var/www/html/admin/cli/purge_caches.php >/dev/null 2>&1 || true

  echo "✅ Cache clearing completed on $pod_name"
  return 0
}

# Function to clear Moodle cache across all PHP pods
clear_moodle_cache_across_pods() {
  local php_resource_name="${1:-php}"  # Default to 'php' deployment/statefulset
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local theme_name="${3:-bcgovpsa}"
  local max_retries="${4:-30}"
  local wait_time="${5:-10}"

  echo "🌐 Clearing Moodle cache across all PHP pods..."
  echo "📍 Namespace: $namespace"
  echo "🔍 PHP resource: $php_resource_name"
  echo "🎨 Theme: $theme_name"

  # Use existing handle_pods_in_resource function
  if handle_pods_in_resource "$php_resource_name" "$namespace" "clear_cache_on_pod" "$theme_name" "" "$max_retries" "$wait_time"; then
    echo "🎉 Cache clearing completed across all PHP pods!"
    return 0
  else
    echo "⚠️  Cache clearing completed with some issues on PHP pods"
    return 1
  fi
}

# Function that combines local and distributed cache clearing
moodle_cache_clear() {
  local namespace="${1:-$DEPLOY_NAMESPACE}"
  local php_resource_name="${2:-php}"
  local theme_name="${3:-bcgovpsa}"
  local use_distributed="${4:-true}"  # Whether to clear cache across PHP pods

  echo "🚀 Starting Moodle cache clearing..."

  local overall_success=true

  # Step 1: Clear cache locally (current pod)
  echo ""
  echo "📍 Step 1: Clearing cache locally (current pod)..."
  if moodle_cache_purge "/var/www/html" "" "$theme_name" "true"; then
    echo "✅ Local cache clearing completed"
  else
    echo "⚠️  Local cache clearing had issues"
    overall_success=false
  fi

  # Step 2: Clear cache across all PHP pods (for RAM disk caches)
  if [[ "$use_distributed" == "true" ]]; then
    echo ""
    echo "📍 Step 2: Clearing cache across all PHP pods..."
    local distributed_result
    clear_moodle_cache_across_pods "$php_resource_name" "$namespace" "$theme_name"
    distributed_result=$?

    case $distributed_result in
      0)
        echo "✅ Distributed cache clearing completed successfully"
        ;;
      *)
        echo "❌ Distributed cache clearing failed"
        overall_success=false
        ;;
    esac
  else
    echo "📍 Step 2: Skipping distributed cache clearing (disabled)"
  fi

  # Step 3: Wait for cache changes to propagate
  echo ""
  echo "📍 Step 3: Waiting for cache changes to propagate..."
  sleep 10

  if [[ "$overall_success" == "true" ]]; then
    echo "🎉 Moodle cache clearing completed successfully!"
    return 0
  else
    echo "⚠️  Moodle cache clearing completed with some issues"
    return 1
  fi
}