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
    # Backup course in current namespace
    backup_course "$courseid" "$current_namespace"
    # Copy backup out to local
    # Find the backup file on the remote cron pod
    cron_pod=$(oc get pods -n "$current_namespace" -l app=cron -o jsonpath='{.items[0].metadata.name}')
    remote_backup_file=$(oc exec -n "$current_namespace" "$cron_pod" -- ls -t /tmp/file-backups/transfer/backup-moodle2-course-${courseid}-*.mbz 2>/dev/null | head -n1)
    if [[ -z "$remote_backup_file" ]]; then
      echo "Backup file for course $courseid not found in pod $cron_pod!"
      continue
    fi

    # 2. Copy the backup file from the remote pod to local
    local_file="${course_transfer_dir}/${target_env}/$(basename "$remote_backup_file")"
    mkdir -p "$(dirname "$local_file")"
    oc cp "$current_namespace/$cron_pod:$remote_backup_file" "$local_file"

    # Continue with your logic (copy to target, update tag, etc.)
    copy_backup_in "$target_ns" "$local_file" "$remote_backup_file"
    update_course_tag "$courseid" "Transferred-${tag}" "$current_namespace"
    rm "$local_file"
    cleanup_old_backups "$current_namespace"
    # Copy backup in to target env
    copy_backup_in "$target_ns" "$local_file" "$backup_file"
    # Update tag in current env
    update_course_tag "$courseid" "Transferred-${tag}" "$current_namespace"
    # Optionally, update tag in target env to mark as imported
    # update_course_tag "$courseid" "Imported-${tag}" "$target_ns"
    # Clean up local file
    rm "$local_file"
    cleanup_old_backups "$current_namespace"
  done
done
