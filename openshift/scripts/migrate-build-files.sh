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
  echo "Source and destination versions do not match. Proceeding..."
else
  # Compare file counts in src_dir and dest_dir
  echo "Source and destination versions match. Checking file counts..."
  src_count=$(find "$src_dir" -type f | wc -l)
  dest_count=$(find "$dest_dir" -type f | wc -l)
  echo "Source file count: $src_count"
  echo "Destination file count: $dest_count"
  if [ "$src_count" -ne "$dest_count" ]; then
    echo "File counts not not match. Checking if files are missing..."
    count_difference=$((src_count - dest_count))
    if [ $count_difference -gt 2 ]; then
      echo "Source has $count_difference more files than destination. Proceeding with migration..."
    else
      echo "DEBUG: FORCE_MIGRATE='${FORCE_MIGRATE}'"
      echo "DEBUG: FORCE_MIGRATE lower='${FORCE_MIGRATE,,}'"
      if [ "${FORCE_MIGRATE,,}" == "yes" ]; then
        echo "Source has $count_difference more files than destination. FORCE_MIGRATE set to TRUE. Proceeding with migration..."
      else
        echo "Destination has $((count_difference * -1)) different files than source. Likely just hidden files and config. Skipping migration."
        exit 0
      fi
    fi
  else
    echo "Skipping file maintenance."
    exit 0
  fi
fi

echo "Replacing Moodle index with maintenance page..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Starting migration... Script should take about 10 min."
echo "Deleting shared Moodle files... in 5...4...3..."

sleep 5

echo "Copy moodledata/muc/config.php..."
cp /var/www/moodledata/muc/config.php /tmp/moodle.config.php

# Use find with -not -name to exclude directories from the file count
initial_count=$(find ${dest_dir} -not -name '.*' | wc -l)
echo "Initial file count: $initial_count"

# Delete all files - including hidden ones
echo "Deleting all files in ${dest_dir}..."
# Delate all files, excluding hidden files and directories
find ${dest_dir} -mindepth 1 -delete

echo "Clearing config caches..."
rm /var/www/moodledata/muc/config.php

# Count the number of files in the destination directory, excluding hidden files and directories
final_count=$(find ${dest_dir} -not -name '.*' | wc -l)
echo "Final file count: $final_count"

# Calculate the number of files deleted
deleted_count=$((initial_count - final_count))
echo "Deleted $deleted_count of $initial_count files."

# Count the number of files remaining in the destination directory
remaining_count=$((initial_count - deleted_count))

# Check if all files have been deleted
if [ $((remaining_count)) -eq 0 ]; then
  echo "All files have been deleted."
else
  echo "Not all files have been deleted. Remaining files:"
  ls -lA ${dest_dir}
fi

echo "Replace Moodle index with maintenance page (again, since we deleted it)..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Copying files..."
# Copy all files, including hidden ones, preserving directory structure
# rsync -a --no-perms --no-owner --no-times ${src_dir}/ ${dest_dir}/
rsync -a --no-perms --no-owner --omit-dir-times --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r ${src_dir}/ ${dest_dir}/

echo "Restore moodledata/muc/config.php..."
cp /tmp/moodle.config.php /var/www/moodledata/muc/config.php

# Create the timestamp file
echo "Creating timestamp file..."
touch "$timestamp_file"

echo "Setting permissions..."
# Set permissions for moodle directory
find $dest_dir -mindepth 1 -type d -exec chmod 755 {} \;
find $dest_dir -mindepth 1 -type f -exec chmod 644 {} \;

sh /usr/local/bin/test-migration-complete.sh
