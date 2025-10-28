#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash..."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /usr/local/bin/_utils.sh

src_dir='/app/public'
dest_dir='/var/www/html'

# Check if the build is newer than the last migration
if should_migrate_by_version; then
  log_info "Source and destination versions do not match. Proceeding..."
else
  # Compare file counts in src_dir and dest_dir
  log_info "Source and destination versions match. Checking file counts..."
  src_count=$(find "$src_dir" -type f | wc -l)
  dest_count=$(find "$dest_dir" -type f | wc -l)
  log_debug "Source file count: $src_count"
  log_debug "Destination file count: $dest_count"
  if [ "$src_count" -ne "$dest_count" ]; then
    log_info "File counts not not match. Checking if files are missing..."
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
