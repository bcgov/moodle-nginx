#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /scripts/_utils.sh

echo "Checking pod logs..."

# Ensure kubeconfig is in a writeable location
export KUBECONFIG=/tmp/kubeconfig

# Set up oc to use the service account token
if [[ -n "$OPENSHIFT_TOKEN" && -n "$OPENSHIFT_SERVER" ]]; then
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true
  oc project "$DEPLOY_NAMESPACE"
fi

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
check_deployment_logs "$deployments_str" "$DEPLOY_NAMESPACE"

echo "Searching for encoding issues in content tables..."
moodle_content_cleanup find
# echo "Replace improperly encoded characters in content tables"
# moodle_content_cleanup replace

# handle Moodle course miggrations between environments
# Based on course tags: Development, Testing, Production
current_namespace=$(oc project -q)
prefix=$(echo "$current_namespace" | sed -E 's/-.*//')
course_transfer_dir="/tmp/file-backups/transfer"

declare -A tag_env_map
tag_env_map["Testing"]="test"
tag_env_map["Production"]="prod"

for tag in "Testing" "Production"; do
  target_env="${tag_env_map[$tag]}"
  target_ns="${prefix}-${target_env}"

  # Only migrate if not already in the target environment
  if [[ "$current_namespace" == *"$target_env" ]]; then
    continue
  fi

  # 1. Find courses to migrate (in current env)
  for courseid in $(find_courses_with_tag "$tag" "$current_namespace"); do
    # 2. Backup course in current env
    backup_course "$courseid" "$current_namespace"
    # 3. Copy backup out to local
    backup_file="/tmp/file-backups/transfer/course-${courseid}.mbz"
    local_file="${course_transfer_dir}/${target_env}/course-${courseid}.mbz"
    mkdir -p "$(dirname "$local_file")"
    copy_backup_out "$current_namespace" "$backup_file" "$local_file"
    # 4. Copy backup in to target env
    copy_backup_in "$target_ns" "$local_file" "$backup_file"
    # 5. Update tag in current env
    update_course_tag "$courseid" "Transferred-${tag}" "$current_namespace"
    # 6. Optionally, update tag in target env to mark as imported
    # update_course_tag "$courseid" "Imported-${tag}" "$target_ns"
    # 7. Clean up local file
    rm "$local_file"
  done
done
