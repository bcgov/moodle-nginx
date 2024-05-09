# stdout_logfile=/dev/stdout
# stdout_logfile_maxbytes=0
# stderr_logfile=/dev/stderr
# stderr_logfile_maxbytes=0

echo "Deleting shared Moodle files... in 30...29...28..."
sleep 30

echo "Deleting shared Moodle files..."
rm -rf /var/www/html/* || true

# echo "Move Moodle web files to /tmp/old..."
# mv /var/www/html/* /tmp/old
# mkdir /var/www/html

echo "Replace Moodle index with maintenance page..."
cp /tmp/moodle_index_during_maintenance.php /var/www/html/index.php

echo "Copying files..."
cp /app/public/* /var/www/html -rp || true

echo "Changing file ownership to www-data..."
chown -R www-data:www-data /var/www/html || true

# echo "Delete [/tmp/old] Moodle web files..."
# rm -rf /var/www/html/*
# mv /var/www/html /var/www/html_old
# mkdir /var/www/html
# rsync -a --delete empty/ /tmp/old

sh /usr/local/bin/test-migration-complete.sh
