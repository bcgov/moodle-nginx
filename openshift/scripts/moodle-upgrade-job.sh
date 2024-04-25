echo "Enabling maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --enable

echo "Waiting 10 minutes to run upgrades after file copy completes (migrate-build-files)..."
sleep 600

echo "Purging cache..."
php /var/www/html/admin/cli/purge_caches.php

echo "Purging missing plugins..."
php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run

echo "Running Moodle upgrades..."
php /var/www/html/admin/cli/upgrade.php --non-interactive

echo "Disabling maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --disable

echo "Run cron..."
php /var/www/html/admin/cli/cron.php
