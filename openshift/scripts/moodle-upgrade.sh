timestamp_file='/var/www/html/last_migration_timestamp'
rerun_block_seconds=3600 # Block rerun if last_run < 1 hour

# Check if the script has been run within the past hour
if [ -f "$timestamp_file" ]; then
  last_run=$(stat -c %Y "$timestamp_file")
  current_time=$(date +%s)
  time_diff=$((current_time - last_run))

  if [ $time_diff -lt rerun_block_seconds ]; then
    echo "The script has been run within the past hour. Skipping upgrade processes."
    exit 0
  fi
fi

echo "Starting Moodle upgrade job..."

cd /

echo "Purging cache..."
php /var/www/html/admin/cli/purge_caches.php

echo "Check for missing plugins..."
php /var/www/html/admin/cli/uninstall_plugins.php --show-missing --show-contrib
# php /var/www/html/admin/cli/uninstall_plugins.php --plugins=format_topcoll --run
echo "Purging missing plugins..."
php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run

echo "Ensuring database encoding is utf8..."
php /var/www/html/admin/cli/mysql_collation.php --collation=utf8mb4_unicode_ci

echo "Running Moodle upgrades..."
php /var/www/html/admin/cli/upgrade.php --non-interactive

echo "Rebuilding theme cache..."
php /var/www/html/admin/cli/build_theme_css.php --themes=boost

echo "Run PHP config check..."
php /var/www/html/info/phpconfigcheck.php

echo "Disabling maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --disable
