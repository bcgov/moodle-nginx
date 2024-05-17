# Enable Maintenance mode (PHP)
echo "Enabling Moodle maintenance mode..."
MAINTENANCE_OUTPUT=$(oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/maintenance.php --enable' --wait 2>&1)
if echo "$MAINTENANCE_OUTPUT" | grep -q "Error"; then
  echo "Failed to enable maintenance mode. Error message: $MAINTENANCE_OUTPUT"
  exit 1
fi
