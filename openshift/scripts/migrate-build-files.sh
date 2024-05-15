echo "Starting migration... Script should take ~10 min..."
echo "Deleting shared Moodle files... in 10...9...8..."
sleep 10

echo "Deleting..."
rm -rf /var/www/html/* || true

# echo "Changing file ownership to www-data..."
# chown -R www-data:www-data /var/www/html || true

echo "Replace Moodle index with maintenance page..."
cp ./config/moodle/moodle_index_during_maintenance.php /var/www/html/index.php

echo "Copying files..."
cp /app/public/* /var/www/html -rp || true

# echo "Changing file ownership to www-data..."
# chown -R www-data:www-data /var/www/html || true

sh /usr/local/bin/test-migration-complete.sh
