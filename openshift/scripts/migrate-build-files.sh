src_dir='/app/public'
dest_dir='/var/www/html'
timestamp_file='/var/www/html/last_migration_timestamp'
rerun_block_seconds=36000 # Block rerun if last_run < 10 hours
rerun_minutes=$((rerun_block_seconds / 60))
rerun_hours=$((rerun_minutes / 60))

# Check if the script has been run within the past hour
if [ -f "$timestamp_file" ]; then
  last_run=$(stat -c %Y "$timestamp_file")
  current_time=$(date +%s)
  time_diff=$((current_time - last_run))
  time_diff_minutes=$((time_diff / 60))
  time_diff_hours=$((time_diff_minutes / 60))

  if [ $time_diff_minutes -gt 60 ]; then
    last_run_message="Last run was $time_diff_hours hours ago."
  else
    last_run_message="Last run was $time_diff_minutes minutes ago."
  fi

  echo "Timestamp file found. $last_run_message"

  if [ $time_diff -lt rerun_block_seconds ]; then
    echo "The script has been run within the past $rerun_hours hours."
    echo "Skipping file maintenance and migration."
    exit 0
  else
    echo "The script has not been run within the past $rerun_hours hours."
    echo "Continuing with file maintenance and migration processes..."
  fi
else
  echo "No timestamp file found. Continuing with file maintenance and migration processes..."
fi

echo "Replacing Moodle index with maintenance page..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Starting migration... Script should take about 10 min."
echo "Deleting shared Moodle files... in 5...4...3..."

sleep 5

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
final_count=$(find ${dest_dir} -type f -not -name '.*' | wc -l)
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

# Create the timestamp file
echo "Creating timestamp file..."
touch "$timestamp_file"

echo "Setting permissions..."
# Set permissions for moodle directory
find $dest_dir -mindepth 1 -type d -exec chmod 755 {} \;
find $dest_dir -mindepth 1 -type f -exec chmod 644 {} \;

sh /usr/local/bin/test-migration-complete.sh
