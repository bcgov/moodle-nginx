#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /scripts/_utils.sh

# Ensure kubeconfig is in a writeable location
export KUBECONFIG=/tmp/kubeconfig

# Set up oc to use the service account token
if [[ -n "$OPENSHIFT_TOKEN" && -n "$OPENSHIFT_SERVER" ]]; then
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true
  oc project "$DEPLOY_NAMESPACE"
fi

echo "Checking pod logs for errors..."

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

# Handle Moodle course miggrations between environments (dev > test > production)
# Based on course tags: Testing, Production
current_namespace=$(oc project -q)
prefix=$(echo "$current_namespace" | sed -E 's/-.*//')
course_transfer_dir="/tmp/file-backups/transfer"

declare -A tag_env_map
tag_env_map["Testing"]="test"
tag_env_map["Production"]="prod"

for tag in "Testing" "Production"; do
  target_env="${tag_env_map[$tag]}"
  target_ns="${prefix}-${target_env}"

  echo "Migrating courses with tag $tag from $current_namespace to $target_ns"

  # Only migrate if not already in the target environment
  if [[ "$current_namespace" == *"$target_env" ]]; then
    continue
  fi

  # 1. Find courses to migrate (in current env)
  echo "DEBUG: Running find_courses_with_tag \"$tag\" \"$current_namespace\""
  course_ids=$(find_courses_with_tag "$tag" "$current_namespace")
  echo "DEBUG: Courses found for tag '$tag': $course_ids"

  if [[ -z "$course_ids" ]]; then
    echo "No courses found with tag '$tag' in namespace $current_namespace"
    continue
  fi

  for courseid in $course_ids; do
    echo "Migrating course $courseid from $current_namespace to $target_ns"
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
