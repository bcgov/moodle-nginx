#!/bin/bash

timestamp_file='/var/www/html/last_migration_timestamp'

# Define error handling functions
delete_pod() {
  local pod=$1
  echo "Restarting pod..."
  oc delete pod $pod
}

log_error_continue() {
  local pod=$1
  echo "Continuing..."
  # Add any additional error handling logic here
}

# Function to check pod logs for errors
check_pod_logs() {
  local pod=$1
  local error_search_string=$2
  local error_handler=${3:-delete_pod}

  # Check for the specific error message in the logs
  LOGS=$(oc logs $pod)

  if echo "$LOGS" | grep -q "$error_search_string"; then
    # Capture the matched error line
    ERROR_LINE=$(echo "$LOGS" | grep -m 1 "$error_search_string")

    echo "Error detected in: $pod"
    echo "Error: $ERROR_LINE."

    # Call the appropriate error handling function
    $error_handler $pod
    return 1
  else
    echo "No errors found in pod: $pod"
    return 0
  fi
}

# Function to wait for all pods in a deployment or statefulset to be running and check for errors
wait_for_deployment_without_errors() {
  local resource=$1
  local error_search_string=${2:-error}
  local error_handler=${3:-delete_pod}
  local max_retries=10
  local retry_count=0
  local wait_time=10

  # Split the resource into type and name
  local resource_type=${resource%%/*}
  local resource_name=${resource##*/}

  # Get the list of pods created for the resource
  local pods=$(oc get pods --selector=${resource_type}=${resource_name} -o jsonpath='{.items[*].metadata.name}')

  for pod in $pods; do
    while true; do
      # Wait until the pod is in the "Running" state
      while [[ $(oc get pod $pod -o 'jsonpath={..status.phase}') != "Running" ]]; do
        if [[ $(oc get pod $pod -o 'jsonpath={..status.phase}') == "Failed" ]]; then
          echo "${resource_name} pod Failed. Retrieving logs..."
          oc logs $pod
          echo "Exiting..."
          exit 1
        fi
        echo "Waiting for pod $pod to be running..."
        sleep 10
      done

      echo "$pod is running. Checking for errors..."
      if ! check_pod_logs $pod $error_search_string $error_handler; then
        echo "Continuing..."
        break
      elif [[ $error_handler == "delete_pod" ]]; then
        echo "Waiting for pod to restart..."
        sleep $wait_time
        retry_count=$((retry_count + 1))

        if [[ $retry_count -ge $max_retries ]]; then
          echo "Error found in pod $pod after $max_retries retries. Exiting..."
          exit 1
        fi
      else
        break
      fi
    done
  done

  echo "All pods in $resource are running and error-free."
}

# Function to manage maintenance mode
manage_maintenance_mode() {
  local action=$1
  local deployment_name=$2

  if [[ $action != "enable" && $action != "disable" ]]; then
    echo "Invalid action: $action. Use 'enable' or 'disable'."
    return 1
  fi

  local script_action="--$action"
  local expected_output=""

  if [[ $action == "enable" ]]; then
    expected_output="Your site is currently in CLI maintenance mode"
  else
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
  local timeout=${3:-90s}
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

  echo "Waiting for $resource to be $condition. Max time: $timeout..."

  while true; do
    if [[ $resource_type == "job" ]]; then
      # Check job status
      job_status=$(oc get jobs $resource_name -o 'jsonpath={..status.failed}')
      if [[ $job_status > 0 ]]; then
        echo "Job $resource_name has failed. Retrieving logs..."
        pod_name=$(oc get pods --selector=job-name=$resource_name -o jsonpath='{.items[0].metadata.name}')
        oc logs $pod_name
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
      local label_selector=""
      if [[ $resource_type == "deployment" ]]; then
        label_selector="deployment=$resource_name"
      elif [[ $resource_type == "sts" || $resource_type == "statefulset" ]]; then
        label_selector="app.kubernetes.io/name=$resource_name"
      fi

      # Check pod status
      output=$(oc wait --for=condition=$condition pod -l $label_selector --timeout=$timeout 2>&1)

      if [[ $scale_direction == "up" ]]; then
        if echo "$output" | grep -q "condition met"; then
          echo "All pods with selector '$label_selector' are in '$condition' condition."
          break
        fi
      elif [[ $scale_direction == "down" ]]; then
        if echo "$output" | grep -q "no matching resources found"; then
          echo "All pods with selector '$label_selector' have scaled down."
          break
        fi
      fi
    fi

    if [[ $retry_count -ge $total_wait_time ]]; then
      echo "Timeout waiting for condition '$condition' with selector '$label_selector'. Exiting..."
      exit 1
    fi

    echo "Retrying... ($(((retry_count + 1) * wait_time))/$timeout)"
    sleep $wait_time
    retry_count=$((retry_count + 1))
  done
}

check_last_run_timestamp() {
  local rerun_block_seconds=36000 # Block rerun if last_run < 10 hours
  local rerun_minutes=$((rerun_block_seconds / 60))
  local rerun_hours=$((rerun_minutes / 60))

  echo "Checking last time maintenance script was run..."

  # Check if the script has been run within the past hour
  if [ -f "$timestamp_file" ]; then
    last_run=$(stat -c %Y "$timestamp_file")
    current_time=$(date +%s)
    time_diff=$((current_time - last_run))
    time_diff_minutes=$((time_diff / 60))
    time_diff_hours=$((time_diff_minutes / 60))

    if [ $time_diff_minutes -gt 60 ]; then
      last_run_message="Last run was $time_diff_hours hours ago."
    else
      last_run_message="Last run was $time_diff_minutes minutes ago."
    fi

    echo "Timestamp file found. $last_run_message"

    if [ $time_diff -lt rerun_block_seconds ]; then
      echo "The script has been run within the past $rerun_hours hours."
      echo "Skipping file maintenance and migration."
      exit 0
    else
      echo "The script has not been run within the past $rerun_hours hours."
      echo "Continuing with file maintenance and migration processes..."
    fi
  else
    echo "No timestamp file found. Continuing..."
  fi
}
