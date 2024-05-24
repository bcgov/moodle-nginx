src_dir='/app/public'
dest_dir='/var/www/html'

echo "Replacing Moodle index with maintenance page..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Starting migration... Script should take about 10 min."
echo "Deleting shared Moodle files... in 10...9...8..."

sleep 10

# Use find with -not -name to exclude directories from the file count
initial_count=$(find ${dest_dir} -type f -not -name '.*' | wc -l)
# Delete all files - including hidden ones
echo "Deleting..."
# find ${dest_dir} -type f -exec rm -f {} \;
rm -rf ${dest_dir}/*
final_count=$(find ${dest_dir} -type f -not -name '.*' | wc -l)

# Calculate the number of files deleted
deleted_count=$((initial_count - final_count))
echo "Deleted $deleted_count of $initial_count files."

remaining_count=$initial_count-$final_count

# Check if all files have been deleted
if [ $remaining_count -eq 0 ]; then
  echo "All files have been deleted."
else
  echo "Not all files have been deleted. Remaining files:"
  ls -l ${dest_dir}
fi

echo "Replace Moodle index with maintenance page (again, since we deleted it)..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Copying files..."
# Copy all files, including hidden ones, preserving directory structure
rsync -a --no-perms --no-owner ${src_dir}/ ${dest_dir}/

# Set permissions for moodle directory
find $dest_dir -type d -mindepth 1 -exec chmod 755 {} \;
find $dest_dir -type f -mindepth 1 -exec chmod 644 {} \;

sh /usr/local/bin/test-migration-complete.sh
