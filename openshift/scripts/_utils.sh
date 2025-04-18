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
scale_deployment() {
  local type=$1
  local deployment=$2
  local pod_count=$3
  local max_pods=$4
  local max_surge="100%"
  local max_unavailable="33%"

  if [[ "$type" == "sts" || "$type" == "statefulset" ]]; then
    cmd="oc scale $type $deployment --replicas=$pod_count"
    # echo "Executing: $cmd"
    $cmd
  elif [[ "$type" == "deployment" ]]; then
    # Remove existing autoscaler if it exists
    if oc get hpa $deployment &> /dev/null; then
      echo "Removing existing HorizontalPodAutoscaler for $deployment"
      delete_resource_if_exists hpa $deployment
    fi

    sleep 10

    cmd="oc scale $type/$deployment --replicas=$pod_count"
    # echo "Executing: $cmd"
    $cmd

    # Add HorizontalPodAutoscaler if MaxPods > PodCount
    local diff=$((max_pods - pod_count))
    if [[ $diff -gt 0 ]]; then
      cmd="oc autoscale $type/$deployment --min $pod_count --max $max_pods --cpu-percent=80"
      # echo "Executing: $cmd"
      $cmd

      # Patch the deployment
      # echo "Executing: oc patch $type/$deployment -p={\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":\"$max_surge\", \"maxUnavailable\":\"33%\"}}}}"
      oc patch $type/$deployment -p="{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":\"$max_surge\", \"maxUnavailable\":\"$max_unavailable\"}}}}"
    fi
  fi

  # Wait for the deployment to be ready
  echo "Waiting for deployment to scale ($pod_count/$max_pods): $type/$deployment..."

  sleep 20

  if wait_for_deployment_without_errors "$type/$deployment"; then
    return 0
  else
    echo "Deployment $deployment failed to scale. Exiting..."
    exit 1
  fi
}

# Function to check logs for a single pod
check_pod_logs() {
  local pod=$1
  local namespace=$2
  local error_search_strings=${3:-"error"}
  local error_handler=${4:-delete_pod}
  local log_file="/tmp/logs/check-pod-logs.log"

  # echo "Checking logs for pod: $pod"
  # echo "Error search strings: $error_search_strings"
  # echo "Error handler: $error_handler"

  # Split the error_search_strings into an array
  IFS=',' read -r -a error_strings <<< "$error_search_strings"

  # Get the list of containers in the pod
  CONTAINERS=$(oc get pod $pod -n $namespace -o jsonpath='{.spec.containers[*].name}')
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

        if check_pod_logs "$pod" "$DEPLOY_NAMESPACE" "$error_search_strings" "$error_handler"; then
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
  local wait_time=${5:-10}

  # Split the resource into type and name
  local resource_type=${resource%%/*}
  local resource_name=${resource##*/}

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
  if ! handle_pods_in_resource "$resource_name" "$DEPLOY_NAMESPACE" "check_pod_logs" "$error_search_string" "$error_handler" $max_retries $wait_time; then
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

  # Scale to 0
  scale_deployment "deployment" "$maintenance_service_name" 0 0

  # Redirect traffic back to application
  # echo "Redirecting traffic to: service/$service_name..."
  patch_route $route_name $service_name
}

# Function to manage maintenance mode
manage_maintenance_mode() {
  local action=$1
  local deployment_name=$2
  local route_name=$3
  local max_retries=${4:-5} # Default to 5 retries
  local wait_time=${5:-30} # Default to 30 seconds between retries
  local retry_count=0

  if [[ $action != "enable" && $action != "disable" ]]; then
    echo "Invalid action: $action. Use 'enable' or 'disable'."
    return 1
  fi

  local script_action="--$action"
  local expected_output=""

  if [[ $action == "enable" ]]; then
    enable_maintenance_mode $deployment_name $route_name
    expected_output="Your site is currently in CLI maintenance mode"
  else
    disable_maintenance_mode $deployment_name
    expected_output="Maintenance mode has been disabled"
  fi

  echo "${action^} maintenance mode..."

  # Ensure Redis Proxy is ready before proceeding
  echo "Ensuring Redis Proxy is ready..."
  if ! wait_for_redis_proxy_ready "redis-proxy" "$DEPLOY_NAMESPACE" 30 10; then
    echo "❌ Redis Proxy is not ready. Exiting..."
    exit 1
  fi
  echo "✔️ Redis Proxy is ready."

  # Get an active pod from the Cron deployment
  echo "Getting an active pod from deployment/$CRON_NAME..."
  local cron_pod=$(oc get pods -l app=$CRON_NAME --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
  if [[ -z "$cron_pod" ]]; then
    echo "❌ No running pods found for deployment/$CRON_NAME. Exiting..."
    exit 1
  fi
  echo "Using pod: $cron_pod"

  # Retry logic for the maintenance mode operation
  while true; do
    maintenance_output=$(oc exec -n $DEPLOY_NAMESPACE $cron_pod -- bash -c "php /var/www/html/admin/cli/maintenance.php $script_action" 2>&1)

    if echo "$maintenance_output" | grep -q "$expected_output"; then
      echo "✔️ Maintenance mode has been successfully ${action}d."
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

# Function to patch route and verify changes
patch_route() {
  local route_name=$1
  local target_service=$2

  # echo "Patching route: $route_name > $target_service..."
  oc patch route $route_name --type=json -p '[{"op": "replace", "path": "/spec/to/name", "value": "'"$target_service"'"}]'

  # Wait for the route change to take effect
  local max_retries=30
  local retry_count=0
  local wait_time=5

  while true; do
    current_target=$(oc get route $route_name -o jsonpath='{.spec.to.name}')
    if [[ "$current_target" == "$target_service" ]]; then
      echo "✔️ Route $route_name successfully updated to $target_service."
      break
    fi
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Route update to $target_service failed after $((max_retries * wait_time)) seconds. Exiting..."
      exit 1
    fi
    echo "Waiting for route $route_name to update to $target_service..."
    sleep $wait_time
    retry_count=$((retry_count + 1))
  done
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

  while true; do
    # Get the list of pods for the resource
    local pods
    pods=$(get_pods_for_resource "$resource_name" "$DEPLOY_NAMESPACE")
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
  else
    echo "❌ Invalid resource format: $resource. Expected format: <type>/<name>"
    return 1
  fi

  # Convert timeout to seconds for calculation
  local timeout_seconds=$(echo $timeout | sed 's/[a-zA-Z]*//g')
  max_retries=$((timeout_seconds / wait_time))

  echo "Waiting for $resource to be $condition ($scale_direction). Max time: $timeout..."

  if [[ $resource_type == "job" ]]; then
    handle_job_status "$resource_name" "$max_retries" "$retry_count" "$wait_time"
  else
    handle_deployment_status "$resource_name" "$condition" "$scale_direction" "$max_retries" "$retry_count" "$wait_time"
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
    echo "'0'"
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
  local redis_name=$1
  local redis_helm_chart=$2
  local values_file=$3
  local upgrade_file=$4

  if helm list -q | grep -q "^$redis_name$"; then
    echo "Helm deployment found. Updating..."
    helm_repo_update_response=$(helm repo update 2>&1)
    helm_upgrade_response=$(helm upgrade --reuse-values -f $upgrade_file $redis_name $redis_helm_chart 2>&1)

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

    if [[ `oc describe sts/$redis_name-node 2>&1` =~ "NotFound" ]]; then
      echo "Helm chart ($redis_name) exists, but StatefulSet ($redis_name-node) was NOT FOUND."
      exit 1
    fi
  else
    echo "Helm deployment ($redis_name) NOT FOUND. Beginning deployment..."
    helm install --values $values_file $redis_name $redis_helm_chart
  fi

  # Clean up the temporary values file
  rm $values_file
  rm $upgrade_file

  echo "Helm updates completed for $redis_name."
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

  # Apply the processed template
  echo "$processed_template" | oc apply -f -
}

check_logs_for_pattern() {
  local pod_name=$1
  local namespace=$2
  local pattern=$3

  local logs=$(oc logs $pod_name -n $namespace 2>&1)
  if echo "$logs" | grep -q "$pattern"; then
    return 0
  else
    return 1
  fi
}

wait_for_galera_sync() {
  local sts_name=$1
  local namespace=$2
  local expected_size=${3:-3}
  local max_retries=${4:-30}
  local wait_time=${5:-10}
  local retry_count=0

  echo "Waiting for MariaDB Galera cluster ($sts_name) to sync in namespace $namespace..."

  # Use handle_pods_in_resource to check all pods
  while true; do
    if ! oc get sts "$sts_name" -n "$namespace" &> /dev/null; then
      echo "❌ StatefulSet $sts_name not found in namespace $namespace. Exiting..."
      return 1
    fi

    if handle_pods_in_resource "$sts_name" "$namespace" check_galera_pod_ready "$expected_size"; then
      echo "✔️ All Galera pods are healthy and synced."
      return 0
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Timeout waiting for MariaDB Galera cluster to sync. Exiting..."
      return 1
    fi

    echo "Waiting for sync... ($retry_count/$max_retries)"
    sleep $wait_time
  done
}

check_galera_pod_ready() {
  local pod=$1
  local namespace=$2
  local expected_size=${3:-3}
  local root_pw="${MARIADB_ROOT_PASSWORD:-root}" # Adjust as needed

  local status_output
  status_output=$(oc exec -n "$namespace" "$pod" -- \
    mysql -u root -p"$root_pw" -e "SHOW STATUS LIKE 'wsrep_%';" 2>/dev/null)

  local cluster_status
  cluster_status=$(echo "$status_output" | awk '/wsrep_cluster_status/ {print $2}')
  local local_state
  local_state=$(echo "$status_output" | awk '/wsrep_local_state_comment/ {print $2}')
  local cluster_size
  cluster_size=$(echo "$status_output" | awk '/wsrep_cluster_size/ {print $2}')

  echo "$pod: cluster_status=$cluster_status, local_state=$local_state, cluster_size=$cluster_size"

  if [[ "$cluster_status" == "Primary" && "$local_state" == "Synced" && "$cluster_size" == "$expected_size" ]]; then
    return 0
  else
    return 1
  fi
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

  echo "Testing Redis Proxy connectivity from pod: $pod"
  if oc exec -n $namespace $pod -- redis-cli -h localhost -p 6379 PING | grep -q "PONG"; then
    echo "✔️ Pod $pod is responding to PING."
    return 0
  else
    echo "❌ Pod $pod is not responding to PING."
    return 1
  fi
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
        # echo "Action: $action"
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

  if [[ "$resource_name" == */* ]]; then
    resource_type=${resource_name%%/*}
    resource_name=${resource_name##*/}
  fi

  if [[ -z "$resource_type" ]]; then
    if oc get statefulset "$resource_name" -n "$namespace" &> /dev/null; then
      resource_type="statefulset"
    elif oc get deployment "$resource_name" -n "$namespace" &> /dev/null; then
      resource_type="deployment"
    else
      echo "❌ Resource $resource_name not found in namespace $namespace. Exiting..." >&2
      return 1
    fi
  fi

  echo "Getting pods for: $resource_type / $resource_name" >&2

  local labels=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.spec.selector.matchLabels}')
  if [[ -z "$labels" ]]; then
    echo "❌ No labels found for resource: $resource_name. Exiting..." >&2
    return 1
  fi

  local label_selector=""
  for key in $(echo "$labels" | jq -r 'keys[]'); do
    local value=$(echo "$labels" | jq -r --arg key "$key" '.[$key]')
    if [[ -n "$label_selector" ]]; then
      label_selector+=","
    fi
    label_selector+="$key=$value"
  done

  echo "Using label selector: $label_selector" >&2

  local pods=$(oc get pods -n "$namespace" --selector="$label_selector" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

  # Do NOT treat empty pod list as an error
  if [[ -z "$pods" ]]; then
    echo "No pods found for resource: $resource_name using selector: $label_selector." >&2
    # Return success (0) with empty pod list
    echo ""
    return 0
  fi

  # Only output the pod names to stdout
  echo "$pods"
  return 0
}
