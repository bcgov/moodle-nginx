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

  if [[ "$type" == "sts" ]]; then
    cmd="oc scale $type $deployment --replicas=$pod_count"
    echo "Executing: $cmd"
    $cmd
  elif [[ "$type" == "deployment" ]]; then
    cmd="oc scale $type/$deployment --replicas=$pod_count"
    echo "Executing: $cmd"
    $cmd

    # Remove existing autoscaler if it exists
    if oc get hpa $deployment &> /dev/null; then
      echo "Removing existing HorizontalPodAutoscaler for $deployment"
      delete_resource_if_exists hpa $deployment
    fi

    # Add HorizontalPodAutoscaler if MaxPods > PodCount
    local diff=$((max_pods - pod_count))
    if [[ $diff -gt 0 ]]; then
      cmd="oc autoscale $type/$deployment --min $pod_count --max $max_pods --cpu-percent=80"
      echo "Executing: $cmd"
      $cmd
    fi

    # Patch the deployment
    echo "Executing: oc patch $type/$deployment -p={\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":\"$max_surge\", \"maxUnavailable\":\"33%\"}}}}"
    oc patch $type/$deployment -p="{\"spec\":{\"strategy\":{\"rollingUpdate\":{\"maxSurge\":\"$max_surge\", \"maxUnavailable\":\"$max_unavailable\"}}}}"
  fi

  # Wait for the deployment to be ready
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
  local error_search_strings=${2:-"error"}
  local error_handler=${3:-delete_pod}
  local log_file="/tmp/logs/check-pod-logs.log"

  # Split the error_search_strings into an array
  IFS=',' read -r -a error_strings <<< "$error_search_strings"

  # Get the list of containers in the pod
  CONTAINERS=$(oc get pod $pod -o jsonpath='{.spec.containers[*].name}')
  # echo "CONTAINERS in pod $pod: $CONTAINERS"
  total_containers=$(echo $CONTAINERS | wc -w)
  # echo "Total containers in pod $pod: $total_containers"

  # Convert CONTAINERS to an array
  IFS=' ' read -r -a container_array <<< "$CONTAINERS"
  # echo "Container array: ${container_array[@]}"

  for container in "${container_array[@]}"; do
    echo " - $container"

    # Check for the specific error messages in the logs
    LOGS=$(oc logs $pod -c $container)
    # echo "Logs for pod: $pod, container: $container"
    # echo "$LOGS"

    for error_search_string in "${error_strings[@]}"; do
      # echo "Searching for error string: $error_search_string"
      if echo "$LOGS" | grep -q "$error_search_string"; then
        # Capture the matched error line
        ERROR_LINE=$(echo "$LOGS" | grep -m 1 "$error_search_string")

        echo " - Error detected:"
        echo " - $ERROR_LINE."

        log_error_to_file "$pod" "$container" "$ERROR_LINE" "$log_file"

        # Call the appropriate error handling function
        $error_handler $pod
        return 0
      fi
    done

    # echo "No errors found in pod: $pod, container: $container"
  done

  return 1
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
  local wait_time=20

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
        echo "Processing pod: $pod"

        if check_pod_logs $pod "$error_search_strings" "$error_handler"; then
          errors_detected=$((errors_detected + 1))
          total_errors=$((total_errors + 1))

          # Wait for the pod to be fully restarted and stabilized
          echo "Waiting for pod $pod to restart and stabilize..."
          oc wait --for=condition=Ready pod/$pod --timeout=300s
          break
        fi
      done

      if [ $errors_detected -eq 0 ]; then
        echo "OK"
        break
      else
        echo "Errors found: $total_errors."
        retry_count=$((retry_count + 1))
        if [ $retry_count -ge $max_retries ]; then
          echo "Max retries reached. Exiting..."
          return 1
        fi
        echo "Waiting for pods to restart and stabilize..."
        sleep $wait_time
      fi
    done

    if [ $total_errors -ne 0 ]; then
      echo "Errors detected: $total_errors"
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

# Function to wait for all pods in a deployment
# or statefulset to be running and check for errors
wait_for_deployment_without_errors() {
  local resource=$1 # e.g. deployment/web
  local error_search_string=${2:-error}
  local error_handler=${3:-delete_pod}
  local max_retries=100
  local retry_count=0
  local wait_time=5

  # Split the resource into type and name
  local resource_type=${resource%%/*}
  local resource_name=${resource##*/}

  # Check if the resource exists
  if ! resource_exists $resource_type $resource_name; then
    echo "Error from server (NotFound): ${resource_type}s.apps \"$resource_name\" not found"
    return 1
  fi

  # Get the list of pods created for the resource
  local pods=$(oc get pods --selector=${resource_type}=${resource_name} -o jsonpath='{.items[*].metadata.name}')

  for pod in $pods; do
    while true; do
      # Get the pod status
      pod_status=$(oc get pod $pod -o 'jsonpath={..status.phase}' 2>&1)

      # Check if the pod is not found
      if echo "$pod_status" | grep -q "NotFound"; then
        echo "Pod $pod not found. Restarting the process..."
        break
      fi

      # Wait until the pod is in the "Running" state
      if [[ "$pod_status" != "Running" ]]; then
        if [[ "$pod_status" == "Failed" ]]; then
          echo "${resource_name} pod Failed. Retrieving logs..."
          oc logs $pod
          echo "Exiting..."
          return 1
        fi
        echo "Waiting for pod $pod to be running..."
        sleep $wait_time
      else
        echo "$pod is running. Checking for errors..."
        if ! check_pod_logs $pod $error_search_string $error_handler; then
          echo "Continuing..."
          break
        elif [[ $error_handler == "delete_pod" ]]; then
          echo "Waiting for pod to restart..."
          sleep $wait_time
          retry_count=$((retry_count + 1))

          if [[ $retry_count -ge $max_retries ]]; then
            echo "Error still found in pod $pod after $max_retries retries. Exiting..."
            return 1
          fi
        else
          break
        fi
      fi
    done
  done

  echo "All pods in $resource are running and error-free."
  return 0
}

# Function to deploy and enable maintenance mode
enable_maintenance_mode() {
  local route_name="$ROUTE_NAME"
  local service_name="$BUILD_NAME"
  local route_timeout="60s"

  echo "Deploying maintenance mode: $route_name > $service_name"

  # Scale to 1 replica
  scale_deployment deployment $service_name 1 1

  # Create / update route
  deploy_resource_from_template ./openshift/web-route-template.yml \
    APP=$APP \
    DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
    WEB_DEPLOYMENT_NAME=$WEB_DEPLOYMENT_NAME \
    APP_HOST_URL=$APP_HOST_URL

  # Print the processed template for debugging
  echo "Processed template:"
  echo "$processed_template"

  # Apply the processed template
  echo "Applying the processed template..."
  echo "$processed_template" | oc apply -f -

  # Redirect traffic
  echo "Redirecting traffic: $route_name > $service_name"
  patch_route $route_name $service_name
}

# Function to disable maintenance mode
disable_maintenance_mode() {
  local route_name="moodle-web"
  local service_name="web"

  echo "Disabling maintenance mode..."

  # Scale to 0
  scale_deployment deployment/$route_name 0 0
  # Redirect traffic back to aapplication
  echo "Redirecting traffic to $service_name..."
  patch_route $route_name $service_name
}

# Function to manage maintenance mode
manage_maintenance_mode() {
  local action=$1
  local deployment_name=$2
  local route_name=$3
  local host_name=$4

  if [[ $action != "enable" && $action != "disable" ]]; then
    echo "Invalid action: $action. Use 'enable' or 'disable'."
    return 1
  fi

  local script_action="--$action"
  local expected_output=""

  if [[ $action == "enable" ]]; then
    enable_maintenance_mode
    expected_output="Your site is currently in CLI maintenance mode"
  else
    disable_mainenance_mode $deployment_name
    expected_output="Maintenance mode has been disabled"
  fi

  echo "${action^} maintenance mode..."
  maintenance_output=$(oc exec deployment/$deployment_name -- bash -c "php /var/www/html/admin/cli/maintenance.php $script_action")

  if echo "$maintenance_output" | grep -q "$expected_output"; then
    echo "Maintenance mode has been successfully ${action}d."
  elif echo "$maintenance_output" | grep -q "Error"; then
    echo "Failed to ${action} maintenance mode. Error message: $maintenance_output"
    exit 1
  else
    echo "$maintenance_output"
  fi
}

# Function to patch route and verify changes
patch_route() {
  local route_name=$1
  local target_service=$2

  echo "Patching route $route_name to target $target_service..."
  oc patch route $route_name --type=json -p '[{"op": "replace", "path": "/spec/to/name", "value": "'"$target_service"'"}]'

  # Wait for the route change to take effect
  local max_retries=30
  local retry_count=0
  local wait_time=5

  while true; do
    current_target=$(oc get route $route_name -o jsonpath='{.spec.to.name}')
    if [[ "$current_target" == "$target_service" ]]; then
      echo "Route $route_name successfully updated to $target_service."
      break
    fi
    if [[ $retry_count -ge $max_retries ]]; then
      echo "Route update to $target_service failed after $((max_retries * wait_time)) seconds. Exiting..."
      exit 1
    fi
    echo "Waiting for route $route_name to update to $target_service..."
    sleep $wait_time
    retry_count=$((retry_count + 1))
  done
}

# Function to wait for deployment pods to be ready or scaled to zero
wait_for() {
  local resource=$1
  local condition=${2:-ready}
  local timeout=${3:-300s}
  local scale_direction=${4:-up}
  local max_retries=30
  local retry_count=0
  local wait_time=10

  # Extract resource type and name
  if [[ $resource == */* ]]; then
    local resource_type=${resource%%/*}
    local resource_name=${resource##*/}
  else
    echo "Invalid resource format: $resource. Expected format: <type>/<name>"
    exit 1
  fi

  # Convert timeout to seconds for calculation
  local timeout_seconds=$(echo $timeout | sed 's/[a-zA-Z]*//g')
  local total_wait_time=$((timeout_seconds + wait_time))

  # If timeout has been adjusted via parameter
  # use the new value by adjusting max_retries
  if [[ $timeout_seconds -ne $((max_retries * wait_time)) ]]; then
    max_retries=$((timeout_seconds / wait_time))
    echo "Timeout adjusted to $timeout. Total wait time: $total_wait_time seconds. Calculated timeout seconds: $timeout_seconds"
    echo "Max retries set to $max_retries."
  fi

  echo "Waiting for $resource to be $condition ($scale_direction). Max time: $timeout..."

  while true; do
    if [[ $resource_type == "job" ]]; then
      # Check job status
      job_status=$(oc get jobs $resource_name -o 'jsonpath={..status.failed}')
      if [[ $job_status > 0 ]]; then
        echo "Job $resource_name has failed. Retrieving logs..."
        pod_name=$(oc get pods --selector=job-name=$resource_name -o jsonpath='{.items[0].metadata.name}')

        error_log_text=$(oc logs $pod_name)
        echo "Error log:"
        echo "$error_log_text"
        echo "Exiting..."
        exit 1
      fi

      job_status=$(oc get jobs $resource_name -o 'jsonpath={..status.succeeded}')
      if [[ $job_status > 0 ]]; then
        echo "Job $resource_name has completed successfully."
        break
      fi

      echo "Waiting for job $resource_name to complete..."
    else
      # Determine the appropriate label selector
      local label_selector="deployment=$resource_name"
      local pods=$(oc get pods --selector=$label_selector -o jsonpath='{.items[*].metadata.name}')

      if [[ -z "$pods" ]]; then
        label_selector="app=$resource_name"
        pods=$(oc get pods --selector=$label_selector -o jsonpath='{.items[*].metadata.name}')
      fi

      if [[ -z "$pods" ]]; then
        label_selector="app.kubernetes.io/name=$resource_name"
        pods=$(oc get pods --selector=$label_selector -o jsonpath='{.items[*].metadata.name}')
      fi

      if [[ $scale_direction == "up" ]]; then
        if [[ -z "$pods" ]]; then
          echo "No pods found for $resource. Retrying..."
        else
          for pod in $pods; do
            output=$(oc wait --for=condition=$condition pod/$pod --timeout=${wait_time}s 2>&1)
            echo "Executing: oc wait --for=condition=$condition pod/$pod --timeout=${wait_time}s"
            echo "Status: $output"
            if echo "$output" | grep -q "condition met"; then
              echo "Pod $pod is in '$condition' condition."
              break 2
            fi
          done
        fi
      elif [[ $scale_direction == "down" ]]; then
        if [[ -z "$pods" ]]; then
          echo "All pods for $resource have scaled down."
          break
        else
          echo "Pods still exist for $resource. Retrying..."
        fi
      fi
    fi

    if [[ $retry_count -ge $max_retries ]]; then
      echo "Timeout waiting for condition '$condition' with selector '$label_selector'. Exiting..."
      return 1
    fi

    echo "Retrying... ($(((retry_count + 1) * wait_time))/$timeout_seconds)"
    sleep $wait_time
    retry_count=$((retry_count + 1))
  done

  return 0
}

check_timestamp() {
  local file_to_test=${1:-/var/www/html/index.php}
  local default_rerun_block_seconds=0 # Default to never blocking reruns
  local rerun_block_seconds=${REBUILD_TIME_LIMIT:-$default_rerun_block_seconds}

  echo "Checking last time maintenance script was run..."

  # Check if the environment variable is set and valid
  if ! [[ "$rerun_block_seconds" =~ ^[0-9]+$ ]]; then
    echo "Invalid REBUILD_TIME_LIMIT value ($REBUILD_TIME_LIMIT). Using default value."
    rerun_block_seconds=$default_rerun_block_seconds
  fi

  # If the value is 0, do not enforce the time limit
  if [ "$rerun_block_seconds" -eq 0 ]; then
    echo "REBUILD_TIME_LIMIT is set to 0. Time limit is not enforced."
    return 0
  fi

  local rerun_minutes=$((rerun_block_seconds / 60))
  local rerun_hours=$((rerun_minutes / 60))
  local last_modified_minutes=$(( ($(date +%s) - $(stat -c %Y $file_to_test)) / 60 ))

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
  elif [[ $value == "0" ]]; then
    echo "'${value}'"
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
  local cpu_limit=null # removed from OS
  local mem_limit=null # removed from OS

  # Validate and format resource values
  cpu_request=$(validate_and_format_resource_value "$cpu_request" "m")
  mem_request=$(validate_and_format_resource_value "$mem_request" "Mi")
  cpu_limit=$(validate_and_format_resource_value "$cpu_limit" "m")
  mem_limit=$(validate_and_format_resource_value "$mem_limit" "Mi")

  cmd="oc set resources $type $deployment --limits=cpu=${cpu_limit},memory=${mem_limit} --requests=cpu=${cpu_request},memory=${mem_request}"
  echo "Set: --limits=cpu=${cpu_limit},memory=${mem_limit} --requests=cpu=${cpu_request},memory=${mem_request}"
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
    return 1
  fi

  echo "Creating HPA: $name to scale at $avg_value"

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

  echo "Creating HPA from template:"
  echo $(cat hpa.yaml)
  oc create -f hpa.yaml

  wait_for_deployment_without_errors "$target"

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
  echo "Executing: $create_cmd"
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
    helm_upgrade_response=$(helm upgrade --reuse-values -f $upgrade_file $redis_name $redis_helm_chart)

    # Output the response for debugging purposes
    echo "1. $helm_upgrade_response"

    # Check if the helm upgrade command failed
    if [[ $? -ne 0 ]]; then
      echo "Helm upgrade failed with the following output:"
      echo "2. $helm_upgrade_response"
      exit 1
    fi

    # Upgrade the Helm deployment with the new values
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
  oc_command="oc describe $resource_type $resource_name"
  echo "Executing: $oc_command"
  oc_output=$($oc_command 2>&1)

  if [[ ! $oc_output =~ "NotFound" ]]; then
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
    process_cmd+=" -p $param"
  done

  # Execute the command
  echo "Deploying resource from template: $template_file"
  echo "Executing: $process_cmd"
  eval $process_cmd | oc apply -f -
}
