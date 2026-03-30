#!/bin/bash
#==============================================================================
# moodle-upgrade.sh
#==============================================================================
# PURPOSE:
#   Orchestrates Moodle database upgrades during deployment. Runs as OpenShift
#   Job to ensure one-time execution per image rebuild. Handles plugin cleanup,
#   database schema updates, and encoding fixes.
#
# UPGRADE PROCESS:
#   1. Enable maintenance mode (prevents user access)
#   2. Check timestamp (skip if recently run)
#   3. Uninstall missing/obsolete plugins
#   4. Fix database collation (utf8mb4_unicode_ci)
#   5. Run Moodle core upgrade (admin/cli/upgrade.php)
#   6. Verify PHP configuration
#
# TIMESTAMP CHECK:
#   Uses IMAGE_REBUILD_TIME_LIMIT to prevent duplicate runs:
#   - Writes timestamp to /var/www/html/last_migration_timestamp
#   - Skips upgrade if run within time limit (seconds)
#   - Set to 0 to always run (useful for testing)
#
# CONFIGURATION:
#   IMAGE_REBUILD_TIME_LIMIT     - Seconds before allowing re-run (default: 0)
#
# EXECUTION CONTEXT:
#   - Runs inside: OpenShift Job (moodle-upgrade.yml)
#   - Image: Moodle PHP container
#   - User: www-data
#   - Path: /var/www/html (Moodle root)
#
# USAGE:
#   # Deployed via OpenShift Job
#   oc create job moodle-upgrade --from=cronjob/moodle-cron
#
#   # Manual execution (inside pod)
#   oc exec deployment/moodle-php -- bash /usr/local/bin/moodle-upgrade.sh
#
# RELATED DOCS:
#   - Job Template: ../moodle-upgrade.yml
#   - Utilities: ./_utils.sh
#   - Moodle CLI: https://docs.moodle.org/en/Administration_via_command_line
#==============================================================================

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

  # echo "Searching for encoding issues in content tables..."
  # moodle_content_cleanup find
  # echo "Replace improperly encoded characters in content tables"
  # moodle_content_cleanup replace

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
php /var/www/html/admin/cli/build_theme_css.php --themes=bcgovpsa

echo "Disabling Moodle maintenance mode..."
php /var/www/html/admin/cli/maintenance.php --disable
