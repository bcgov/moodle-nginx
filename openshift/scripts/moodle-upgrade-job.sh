echo "Enabling maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --enable

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
