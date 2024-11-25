src_dir='/app/public'
dest_dir='/var/www/html'

echo "Replacing Moodle index with maintenance page..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Starting migration... Script should take about 10 min."
echo "Deleting shared Moodle files... in 10...9...8..."

sleep 10

# Use find with -not -name to exclude directories from the file count
initial_count=$(find ${dest_dir} -not -name '.*' | wc -l)
echo "Initial file count: $initial_count"

# Delete all files - including hidden ones
echo "Deleting all files in ${dest_dir}..."
# Delate all files, excluding hidden files and directories
find ${dest_dir} -mindepth 1 -delete

sleep 10

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
rsync -a --no-perms --no-owner --chmod=Du=rwx,Dg=rx,Do=rx,Fu=rw,Fg=r,Fo=r ${src_dir}/ ${dest_dir}/

echo "Setting permissions..."
# Set permissions for moodle directory
find $dest_dir -mindepth 1 -type d -exec chmod 755 {} \;
find $dest_dir -mindepth 1 -type f -exec chmod 644 {} \;

sh /usr/local/bin/test-migration-complete.sh
