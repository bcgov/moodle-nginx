#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash..."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /usr/local/bin/_utils.sh

echo "Starting Moodle upgrade job..."

cd /

# Check if the script has been run within the time limit
if [ check_last_run_timestamp -gt 0 ]; then
  echo "The script has been run recently, skip upgrades."
  # exit 0
else
  echo "Running file maintenance and migration processes..."

  echo "Check for missing plugins..."
  php /var/www/html/admin/cli/uninstall_plugins.php --show-missing --show-contrib
  # php /var/www/html/admin/cli/uninstall_plugins.php --plugins=format_topcoll --run
  echo "Purging missing plugins..."
  php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run

  echo "Ensuring database encoding is utf8..."
  php /var/www/html/admin/cli/mysql_collation.php --collation=utf8mb4_unicode_ci

  echo "Running Moodle upgrades..."
  php /var/www/html/admin/cli/upgrade.php --non-interactive

  echo "Run PHP config check..."
  php /var/www/html/info/phpconfigcheck.php
fi

echo "Purging cache..."
php /var/www/html/admin/cli/purge_caches.php

echo "Rebuilding theme cache..."
php /var/www/html/admin/cli/build_theme_css.php --themes=boost

echo "Disabling maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --disable
