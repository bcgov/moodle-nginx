# Source the utility script
source ./openshift/scripts/_utils.sh

helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update

echo "Deploying database backups to: $DB_BACKUP_DEPLOYMENT_NAME..."

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
echo "Backup container deployment completed."
