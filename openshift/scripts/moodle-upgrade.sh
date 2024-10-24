echo "Starting Moodle upgrade job..."

# echo "Enabling maintenance mode..."
# php /var/www/html/admin/cli/maintenance.php --enable

# echo "Waiting 10 minutes to run upgrades after file copy completes (migrate-build-files)..."
# sleep 600

cd /

echo "Purging cache..."
php /var/www/html/admin/cli/purge_caches.php

echo "Check for missing plugins..."
php /var/www/html/admin/cli/uninstall_plugins.php --show-missing --show-contrib
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
