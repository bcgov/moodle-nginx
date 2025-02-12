#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash..."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /scripts/_utils.sh

echo "Checking pod logs, using shell: $SHELL"

# Define the list of deployments and their corresponding error messages and handling functions
declare -A DEPLOYMENTS
DEPLOYMENTS=(
  ["deployment=php"]="error,critical"
  ["app=redis-proxy"]="err:"
  ["app.kubernetes.io/name=redis"]="lost"
  ["deployment=web"]="error"
  ["app.kubernetes.io/name=mariadb-galera"]="Aborted,bogus"
  ["app=cron"]="error"
)

# Loop through each deployment
for DEPLOYMENT_NAME in "${!DEPLOYMENTS[@]}"; do
  echo "Checking for pods in: $DEPLOYMENT_NAME"

  # Get the list of pods in the deployment
  PODS=$(oc get pods -l $DEPLOYMENT_NAME -o jsonpath='{.items[*].metadata.name}')

  # Loop through each pod and check the logs for errors
  for POD in $PODS; do
    if check_pod_logs $POD "${DEPLOYMENTS[$DEPLOYMENT_NAME]}"; then
      echo "OK"
    fi
  done
done
