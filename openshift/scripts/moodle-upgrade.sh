#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash..."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /usr/local/bin/_utils.sh

echo "Starting Moodle upgrade job..."

echo "Enabling Moodle maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --enable

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

  echo "Searching for encoding issues in content tables..."
  moodle_content_cleanup find
  # echo "Replace improperly encoded characters in content tables"
  # moodle_content_cleanup replace

  echo "Running Moodle upgrades..."
  php /var/www/html/admin/cli/upgrade.php --non-interactive

  echo "Run PHP config check..."
  php /var/www/html/info/phpconfigcheck.php
else
  echo "Skipping Moodle upgrade as it has been run within $IMAGE_REBUILD_TIME_LIMIT seconds."
fi

echo "Cache clearing across all pods..."

# Clear cache on the current pod and all PHP pods (which have PHP installed)
# This addresses RAM disk cache issues where each pod has its own local cache
echo "🚀 Starting cache clearing..."

# Set the PHP resource name based on your deployment
# Common names: php, moodle-php, app-php
PHP_RESOURCE_NAME="${PHP_RESOURCE_NAME:-php}"
DEPLOY_NAMESPACE="${DEPLOY_NAMESPACE:-950003-dev}"

echo "📍 Clearing cache in namespace: $DEPLOY_NAMESPACE"
echo "🔍 Using PHP resource: $PHP_RESOURCE_NAME"

if moodle_cache_clear "$DEPLOY_NAMESPACE" "$PHP_RESOURCE_NAME" "bcgovpsa" "true"; then
  echo "✅ Cache clearing completed successfully"
else
  echo "⚠️  Cache clearing completed with some issues"
  echo "🔄 This is normal if some pods were busy or restarting"
fi

echo "Disabling Moodle maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --disable
