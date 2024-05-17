src_dir='/app/public'
dest_dir='/var/www/html'

echo "Starting migration... Script should take ~10 min..."
echo "Deleting shared Moodle files... in 10...9...8..."
sleep 10

echo "Deleting..."
rm -rf ${dest_dir}/* || true

# echo "Changing file ownership to www-data..."
# chown -R www-data:www-data /var/www/html || true

echo "Replace Moodle index with maintenance page..."
cp ./config/moodle/moodle_index_during_maintenance.php ${dest_dir}/index.php

echo "Copying files..."
cp ${src_dir}/* ${dest_dir} -rp || true

# echo "Changing file ownership to www-data..."
# chown -R www-data:www-data /var/www/html || true

sh /usr/local/bin/test-migration-complete.sh
