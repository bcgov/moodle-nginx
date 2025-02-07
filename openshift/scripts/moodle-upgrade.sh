#!/bin/bash

# Source the utility script
source ./openshift/scripts/_utils.sh

echo "Starting Moodle upgrade job..."

# Check if the script has been run within the past hour
check_last_run_timestamp

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
