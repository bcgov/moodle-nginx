# Source the utility script
source ./openshift/scripts/_utils.sh

helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update

echo "Deploying database backups to: $DB_BACKUP_DEPLOYMENT_NAME..."

# Ensure backup storage secrets exist
echo "🔍 Checking for backup storage secrets..."
if ! oc get secret moodle-db-backup-storage-secrets &> /dev/null; then
  echo "⚠️  Secret 'moodle-db-backup-storage-secrets' not found. Creating with default empty values..."

  # Create the secret with empty values (can be updated later with actual credentials)
  oc create secret generic moodle-db-backup-storage-secrets \
    --from-literal=ftp-password='' \
    --from-literal=ftp-url='' \
    --from-literal=ftp-user='' \
    --from-literal=mssql-sa-password='' \
    --from-literal=webhook-url=''

  if [[ $? -eq 0 ]]; then
    echo "✅ Created backup storage secrets with empty values"
    echo "📝 Note: Update the secret values later if FTP or webhook functionality is needed"
  else
    echo "❌ Failed to create backup storage secrets"
    exit 1
  fi
else
  echo "✅ Backup storage secrets already exist"
fi

# Generate install.yaml for install
cat <<EOF > install.yaml
image:
  repository: "$BACKUP_HELM_CHART"
  pullPolicy: Always
  tag: dev

persistence:
  backup:
    accessModes: ["ReadWriteMany"]
    storageClassName: netapp-file-standard
  verification:
    storageClassName: netapp-file-standard

backupConfig: |
  mariadb=$DB_HOST:$DB_PORT/$DB_NAME
  0 1 * * * default ./backup.sh -s
  0 4 * * * default ./backup.sh -s -v all

networkPolicy:
  enabled: true

db:
  secretName: moodle-secrets
  usernameKey: database-user
  passwordKey: database-password

env:
  DATABASE_SERVICE_NAME:
    value: "$DB_HOST"
  ENVIRONMENT_FRIENDLY_NAME:
    value: "Backups"
EOF

# Generate upgrade.yaml for upgrade
cat <<EOF > upgrade.yaml
backupConfig: |
  mariadb=$DB_HOST:$DB_PORT/$DB_NAME
  0 1 * * * default ./backup.sh -s
  0 4 * * * default ./backup.sh -s -v all
networkPolicy:
  enabled: true
EOF

# Use the utility function for upgrade
create_or_update_helm_deployment "$DB_BACKUP_DEPLOYMENT_NAME" "$BACKUP_HELM_CHART" "install.yaml" "upgrade.yaml"
upgrade_rc=$?

# Clean up the temporary values file
rm upgrade.yaml
rm install.yaml

if [[ $upgrade_rc -ne 0 ]]; then
  echo "Backup container update FAILED (see above for details)."
  exit 1
fi

if [[ `oc describe deployment $DB_BACKUP_DEPLOYMENT_FULL_NAME 2>&1` =~ "NotFound" ]]; then
  echo "Backup Helm exists, but deployment NOT FOUND."
  exit 1
else
  echo "Backup deployment FOUND. Updating image..."
  oc set image deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME backup-storage=$DB_BACKUP_IMAGE
fi

# Verify deployment and troubleshoot if needed
echo "🔍 Verifying backup storage deployment..."
if ! wait_for "deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME" "ready" "300s"; then
  echo "⚠️  Backup storage deployment not ready. Checking for issues..."

  # Get pod status and events
  echo "📋 Pod status:"
  oc get pods -l app.kubernetes.io/name=backup-storage

  echo "📋 Recent events:"
  oc get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' | tail -10

  echo "📋 Checking required secrets:"
  oc get secret moodle-db-backup-storage-secrets || echo "❌ Backup storage secrets missing"
  oc get secret moodle-secrets || echo "❌ Database secrets missing"

  echo "⚠️  Backup storage deployment has issues, but continuing..."
else
  echo "✅ Backup storage deployment is ready"
fi

echo "Backup container deployment completed."
