#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /scripts/_utils.sh

echo "Checking pod logs..."

# Define the list of deployments and their corresponding error messages and handling functions
declare -A DEPLOYMENTS
DEPLOYMENTS=(
  ["deployment=php"]="error,critical"
  ["app=redis-proxy"]="err:"
  ["app.kubernetes.io/name=mariadb-galera"]="Aborted,bogus"
  # ["app.kubernetes.io/name=redis"]="lost"
  # ["deployment=web"]="error"
  # ["app=cron"]="error"
)

# Convert the DEPLOYMENTS array to a string and pass it to the function
deployments_str=$(declare -p DEPLOYMENTS)
check_deployment_logs "$deployments_str"
