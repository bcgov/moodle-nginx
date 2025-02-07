#!/bin/bash

# Source the utility script
source _utils.sh

echo "Checking pod logs, using shell: $SHELL"

# Define the list of deployments and their corresponding error messages and handling functions
declare -A DEPLOYMENTS
DEPLOYMENTS=(
  ["deployment=php"]="error"
  ["app=redis-proxy"]="err:"
  ["app.kubernetes.io/name=redis"]="lost"
  ["deployment=web"]="error"
  ["app.kubernetes.io/name=mariadb-galera"]="Aborted"
)

# Loop through each deployment
for DEPLOYMENT_NAME in "${!DEPLOYMENTS[@]}"; do
  echo "Checking for pods in: $DEPLOYMENT_NAME"

  # Get the list of pods in the deployment
  PODS=$(oc get pods -l $DEPLOYMENT_NAME -o jsonpath='{.items[*].metadata.name}')

  # Loop through each pod and check the logs
  for POD in $PODS; do
    echo "Checking logs for pod: $POD"
    check_pod_logs $POD ${DEPLOYMENTS[$DEPLOYMENT_NAME]}
  done
done
