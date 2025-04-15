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

# Ensure IMAGE_REBUILD_TIME_LIMIT is set and valid
if [[ -z "$IMAGE_REBUILD_TIME_LIMIT" || ! "$IMAGE_REBUILD_TIME_LIMIT" =~ ^[0-9]+$ ]]; then
  echo "IMAGE_REBUILD_TIME_LIMIT is unset or invalid. Defaulting to run the upgrade."
  IMAGE_REBUILD_TIME_LIMIT=0
fi

# Check if the script has been run within the time limit
if check_timestamp; then
  echo "Running file maintenance and migration processes..."

  echo "Check for missing plugins..."
  php /var/www/html/admin/cli/uninstall_plugins.php --show-missing --show-contrib
  # php /var/www/html/admin/cli/uninstall_plugins.php --plugins=format_topcoll --run
  echo "Purging missing plugins..."
  php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run

  echo "Ensuring database encoding is utf8..."
  php /var/www/html/admin/cli/mysql_collation.php --collation=utf8mb4_unicode_ci  > /dev/null

  echo "Running Moodle upgrades..."
  php /var/www/html/admin/cli/upgrade.php --non-interactive

  echo "Run PHP config check..."
  php /var/www/html/info/phpconfigcheck.php
else
  echo "Skipping Moodle upgrade as it has been run within $IMAGE_REBUILD_TIME_LIMIT seconds."
fi

echo "Purging cache..."
php /var/www/html/admin/cli/purge_caches.php

echo "Rebuilding theme cache..."
php /var/www/html/admin/cli/build_theme_css.php --themes=boost

echo "Disabling Moodle maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --disable
