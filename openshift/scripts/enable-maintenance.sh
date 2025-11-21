#!/bin/bash
#==============================================================================
# enable-maintenance.sh
#==============================================================================
# PURPOSE:
#   Enable Moodle maintenance mode via PHP CLI. Displays maintenance message
#   to users while deployments or upgrades are in progress.
#
# USAGE:
#   ./openshift/scripts/enable-maintenance.sh
#
# RELATED:
#   - Disable: manage_maintenance_mode "disable" (from _utils.sh)
#   - Message: ../../config/maintenance/index.html
#==============================================================================

# Enable Maintenance mode (PHP)
echo "Enabling Moodle maintenance mode..."
MAINTENANCE_OUTPUT=$(oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/maintenance.php --enable' --wait 2>&1)
if echo "$MAINTENANCE_OUTPUT" | grep -q "Error"; then
  echo "Failed to enable maintenance mode. Error message: $MAINTENANCE_OUTPUT"
  exit 1
fi
