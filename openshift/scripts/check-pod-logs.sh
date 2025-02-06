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

      echo "Error detected in: $POD"
      echo "Error: $ERROR_LINE."

      # Call the appropriate error handling function
      case $DEPLOYMENT_NAME in
        php)
          delete_pod $POD
          ;;
        redis-proxy)
          delete_pod $POD
          ;;
        web)
          delete_pod $POD
          ;;
        *)
          echo "No error handling function defined for deployment: $DEPLOYMENT_NAME"
          ;;
      esac
      break
    else
      echo "No errors found."
    fi
  done
done
