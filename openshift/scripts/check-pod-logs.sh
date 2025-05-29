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
    backup_course "$courseid" "$current_namespace"

    # Find the backup file on the remote cron pod
    cron_pod=$(oc get pods -n "$current_namespace" -l app=cron -o jsonpath='{.items[0].metadata.name}')
    echo "DEBUG: cron_pod='$cron_pod'"
    if [[ -z "$cron_pod" ]]; then
      echo "No cron pod found in namespace $current_namespace"
      continue
    fi

    remote_backup_file=$(oc exec -n "$current_namespace" "$cron_pod" -- bash -c "ls -t /tmp/file-backups/transfer/backup-moodle2-course-${courseid}-*.mbz 2>/dev/null | head -n1")
    echo "DEBUG: remote_backup_file='$remote_backup_file'"
    if [[ -z "$remote_backup_file" ]]; then
      echo "Backup file for course $courseid not found in pod $cron_pod"
      continue
    fi

    # Copy the backup file from the remote pod to local
    local_file="${course_transfer_dir}/${target_env}/$(basename "$remote_backup_file")"
    echo "DEBUG: local_file='$local_file'"
    mkdir -p "$(dirname "$local_file")"

    # Copy backup out of cron pod to checck-pod-logs
    copy_backup_out "$current_namespace" "$cron_pod" "$remote_backup_file" "$local_file"

    # Copy backup in to target env
    target_cron_pod=$(oc get pods -n "$target_ns" -l app=cron -o jsonpath='{.items[0].metadata.name}')
    echo "DEBUG: target_cron_pod='$target_cron_pod'"
    if [[ -z "$target_cron_pod" ]]; then
      echo "No cron pod found in namespace $target_ns"
      continue
    fi

    copy_backup_in "$target_ns" "$target_cron_pod" "$local_file" "$remote_backup_file"

    # Update tag in current env
    update_course_tag "$courseid" "Transferred-${tag}" "$current_namespace"
    # Clean up local file
    if [[ -f "$local_file" ]]; then
      rm "$local_file"
    fi
    # Clean up old backups in the cron pod
    cleanup_old_backups "$current_namespace" "$cron_pod"
  done
done
