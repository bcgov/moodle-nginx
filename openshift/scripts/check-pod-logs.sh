#!/bin/bash

echo "Checking pod logs, using shell: $SHELL"

# Define the list of deployments and their corresponding error messages and handling functions
declare -A DEPLOYMENTS
DEPLOYMENTS=(
  ["php"]="error"
  ["redis-proxy"]="err:"
  ["redis-node"]="lost"
  ["web"]="error"
  # ["mariadb-galera"]="Aborted"
)

# Define error handling functions
handle_php_error() {
  local pod=$1
  local error_line=$2
  echo "Error found in pod: $pod. Error: $error_line. Deleting pod..."
  oc delete pod $pod
}

handle_redis_proxy_error() {
  local pod=$1
  local error_line=$2
  echo "Error found in pod: $pod. Error: $error_line. Restarting pod..."
  oc delete pod $pod
}

handle_web_error() {
  local pod=$1
  local error_line=$2
  echo "Error found in pod: $pod. Error: $error_line. Logging error and continuing..."
  # Add any additional error handling logic here
}

# Loop through each deployment
for DEPLOYMENT_NAME in "${!DEPLOYMENTS[@]}"; do
  echo "Checking deployment: $DEPLOYMENT_NAME"

  # Get the list of pods in the deployment
  PODS=$(oc get pods -l deployment=$DEPLOYMENT_NAME -o jsonpath='{.items[*].metadata.name}')

  # Loop through each pod and check the logs
  for POD in $PODS; do
    echo "Checking logs for pod: $POD"
    LOGS=$(oc logs $POD)

    # Check for the specific error message in the logs
    ERROR_MESSAGE=${DEPLOYMENTS[$DEPLOYMENT_NAME]}

    if echo "$LOGS" | grep -q "$ERROR_MESSAGE"; then
      # Capture the matched error line
      ERROR_LINE=$(echo "$LOGS" | grep -m 1 "$ERROR_MESSAGE")
      echo "Error found in pod: $POD. Error: $ERROR_LINE."

      # Call the appropriate error handling function
      case $DEPLOYMENT_NAME in
        php)
          handle_php_error $POD "$ERROR_LINE"
          ;;
        redis-proxy)
          handle_redis_proxy_error $POD "$ERROR_LINE"
          ;;
        web)
          handle_web_error $POD "$ERROR_LINE"
          ;;
        *)
          echo "No error handling function defined for deployment: $DEPLOYMENT_NAME"
          ;;
      esac
      break
    else
      echo "No errors found in pod: $POD"
    fi
  done
done
