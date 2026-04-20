#!/bin/bash
#==============================================================================
# migrate-build-files.sh
#==============================================================================
# PURPOSE:
#   Safely migrate Moodle application files from build container (/app/public)
#   to runtime volume (/var/www/html) during deployment. Includes version
#   checking and downgrade protection to prevent deploying outdated code.
#
# SAFETY FEATURES:
#   - Version comparison: Prevents accidental downgrades
#   - File count validation: Detects incomplete builds
#   - Force migrate option: Override safety checks when needed
#   - Timestamp tracking: Avoids redundant migrations
#
# VERSION CHECKING:
#   Compares version.php in source and destination:
#   - PROCEED: Source version > destination version
#   - ABORT: Source version < destination (dangerous downgrade)
#   - SKIP: Versions match and file counts match
#
# MIGRATION PROCESS:
#   1. Check version compatibility (should_migrate_by_version)
#   2. Compare file counts if versions match
#   3. Copy files from /app/public to /var/www/html
#   4. Set proper ownership (www-data:www-data)
#   5. Record migration timestamp
#
# CONFIGURATION:
#   FORCE_MIGRATE            - "yes" to override safety checks
#   IMAGE_REBUILD_TIME_LIMIT - Seconds before allowing re-migration
#
# EXECUTION CONTEXT:
#   - Runs inside: OpenShift Job (migrate-build-files.yml)
#   - Source: /app/public (read-only volume from build image)
#   - Destination: /var/www/html (persistent volume)
#   - User: root (requires chown for www-data)
#
# USAGE:
#   # Normal migration (with safety checks)
#   ./migrate-build-files.sh
#
#   # Force migration (skip version checks)
#   export FORCE_MIGRATE="yes"
#   ./migrate-build-files.sh
#
#   # Deployed via OpenShift Job
#   oc create job migrate-build-files --from=job/migrate-build-files-template
#
# RELATED DOCS:
#   - Job Template: ../migrate-build-files.yml
#   - Utilities: ./_utils.sh (should_migrate_by_version)
#==============================================================================

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash..."
  exec /bin/bash "$0" "$@"
fi

# Universal _utils.sh loader - works in all environments
# Priority: same-dir > /scripts > /usr/local/bin > ./openshift/scripts
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

src_dir='/app/public'
dest_dir='/var/www/html'

# Extract Moodle release versions from version.php in source and destination.
# Moodle version.php contains: $release = '4.5.1 (Build: 20250113)';
# We extract just the semver portion (e.g., "4.5.1") for comparison.
extract_moodle_version() {
  local version_file="$1/version.php"
  if [[ -f "$version_file" ]]; then
    grep -oP "\\\$release\s*=\s*'\K[0-9]+\.[0-9]+(\.[0-9]+)?" "$version_file" || echo ""
  else
    echo ""
  fi
}

src_version=$(extract_moodle_version "$src_dir")
dest_version=$(extract_moodle_version "$dest_dir")
log_info "Source version: ${src_version:-<not found>}"
log_info "Destination version: ${dest_version:-<not found>}"

# Check if the build is newer than the last migration
should_migrate_by_version "$dest_version" "$src_version" "patch"
migration_result=$?

if [ $migration_result -eq 0 ]; then
  log_info "Source and destination versions do not match. Proceeding..."
elif [ $migration_result -eq 2 ]; then
  log_error "CRITICAL: Dangerous version downgrade detected!"
  log_error "Migration aborted to protect against deploying outdated code"
  exit 1
else
  # migration_result -eq 1 (no migration needed)
  # Compare file counts in src_dir and dest_dir
  log_info "Source and destination versions match. Checking file counts..."
  src_count=$(find "$src_dir" -type f | wc -l)
  dest_count=$(find "$dest_dir" -type f | wc -l)
  log_debug "Source file count: $src_count"
  log_debug "Destination file count: $dest_count"
  if [ "$src_count" -ne "$dest_count" ]; then
    log_info "File counts do not match. Checking if files are missing..."
    count_difference=$((src_count - dest_count))
    if [ $count_difference -gt 2 ]; then
      log_info "Source has $count_difference more files than destination. Proceeding with migration..."
    else
      log_debug "FORCE_MIGRATE='${FORCE_MIGRATE}'"
      log_debug "FORCE_MIGRATE lower='${FORCE_MIGRATE,,}'"
      if [ "${FORCE_MIGRATE,,}" == "yes" ]; then
        log_info "Source has $count_difference more files than destination. FORCE_MIGRATE set to TRUE. Proceeding with migration..."
      else
        log_info "Destination has $((count_difference * -1)) different files than source. Likely just hidden files and config. Skipping migration."
        exit 0
      fi
    fi
  else
    log_info "File counts match. Checking FORCE_MIGRATE flag..."
    log_debug "FORCE_MIGRATE='${FORCE_MIGRATE}'"
    log_debug "FORCE_MIGRATE lower='${FORCE_MIGRATE,,}'"
    if [ "${FORCE_MIGRATE,,}" == "yes" ]; then
      log_info "File counts match but FORCE_MIGRATE set to YES. Proceeding with migration..."
    else
      log_info "File counts match and FORCE_MIGRATE not set. Skipping file maintenance."
      exit 0
    fi
  fi
fi

log_info "Replacing Moodle index with maintenance page..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

log_info "Starting migration... Script should take about 10 min."
log_info "Deleting shared Moodle files... in 5...4...3..."

sleep 5

log_debug "Copy moodledata/muc/config.php..."
cp /var/www/moodledata/muc/config.php /tmp/moodle.config.php

# Count all files (including hidden ones) before deletion for accurate tracking
initial_count=$(find ${dest_dir} -mindepth 1 -type f | wc -l)
log_debug "Initial file count (including all files): $initial_count"

# Delete all files - including hidden ones
log_info "Deleting all files in ${dest_dir}..."
find ${dest_dir} -mindepth 1 -delete

log_debug "Clearing config caches..."
rm -f /var/www/moodledata/muc/config.php

# Count remaining files after deletion
final_count=$(find ${dest_dir} -mindepth 1 -type f | wc -l)
log_debug "Final file count: $final_count"

# Calculate the number of files actually deleted
deleted_count=$((initial_count - final_count))
log_info "Deleted $deleted_count of $initial_count files."

# Check if all files have been deleted
if [ $final_count -eq 0 ]; then
  log_info "All files have been deleted successfully."
else
  log_warn "Not all files have been deleted. $final_count files remaining:"
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    ls -lA ${dest_dir}
  else
    # Just show count of remaining files by type in normal mode
    log_info "  Regular files: $(find ${dest_dir} -type f | wc -l)"
    log_info "  Directories: $(find ${dest_dir} -type d | wc -l)"
  fi
fi

log_info "Replace Moodle index with maintenance page (again, since we deleted it)..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

log_info "Copying files..."
# Copy all files, including hidden ones, preserving directory structure
# rsync -a --no-perms --no-owner --no-times ${src_dir}/ ${dest_dir}/
rsync -a --no-perms --no-owner --omit-dir-times --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r ${src_dir}/ ${dest_dir}/

log_debug "Restore moodledata/muc/config.php..."
cp /tmp/moodle.config.php /var/www/moodledata/muc/config.php

# Create the timestamp file
log_debug "Creating timestamp file..."
touch "$timestamp_file"

log_info "Setting permissions..."
# Set permissions for moodle directory
find $dest_dir -mindepth 1 -type d -exec chmod 755 {} \;
find $dest_dir -mindepth 1 -type f -exec chmod 644 {} \;

sh /usr/local/bin/test-migration-complete.sh
