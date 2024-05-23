src_dir='/app/public'
dest_dir='/var/www/html'

echo "Replacing Moodle index with maintenance page..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Starting migration... Script should take about 10 min."
echo "Deleting shared Moodle files... in 10...9...8..."

sleep 10

# Count the number of files before deletion
initial_count=$(find ${dest_dir} -type f | wc -l)

echo "Deleting..."
rm -rf ${dest_dir}/* || true

# Count the number of files after deletion
final_count=$(find ${dest_dir} -type f | wc -l)

# Calculate the number of files deleted
deleted_count=$((initial_count - final_count))
echo "Deleted $deleted_count of $initial_count files."

# Check if all files have been deleted
if [ $final_count -eq 0 ]; then
  echo "All files have been deleted."
else
  echo "Not all files have been deleted. Remaining files:"
  ls -l ${dest_dir}
fi

echo "Replace Moodle index with maintenance page (again, since we deleted it)..."
cp /tmp/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Copying files..."
cp ${src_dir}/* ${dest_dir} -rp # || true
cp ${src_dir}/.* ${dest_dir} -rp

# Set permissions for moodle directory
find $dest_dir -type d -mindepth 1 -exec chmod 755 {} \;
find $dest_dir -type f -mindepth 1 -exec chmod 644 {} \;
# chown -R root:root $dest_dir

sh /usr/local/bin/test-migration-complete.sh
