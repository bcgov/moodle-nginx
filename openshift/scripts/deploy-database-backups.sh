# Source the utility script
source ./openshift/scripts/_utils.sh

helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update

echo "Deploying database backups to: $DB_BACKUP_DEPLOYMENT_NAME..."

if helm list -q | grep -q "^$DB_BACKUP_DEPLOYMENT_NAME$"; then
  echo "Helm deployment found. Updating..."

  # Generate temp-values.yaml for upgrade
  cat <<EOF > temp-values.yaml
backupConfig: |
  mariadb=$DB_HOST:$DB_PORT/$DB_NAME
  0 1 * * * default ./backup.sh -s
  0 4 * * * default ./backup.sh -s -v all
networkPolicy:
  enabled: true
EOF

  # Use the utility function for upgrade
  create_or_update_helm_deployment "$DB_BACKUP_DEPLOYMENT_NAME" "$BACKUP_HELM_CHART" "temp-values.yaml"
  upgrade_rc=$?

  # Clean up the temporary values file
  rm temp-values.yaml

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
  echo "Backup container updates completed."
else
  echo "Helm $DB_BACKUP_DEPLOYMENT_NAME NOT FOUND. Beginning deployment..."

  # Generate config.yaml for install
  cat <<EOF > config.yaml
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

  # Use the utility function for install
  create_or_update_helm_deployment "$DB_BACKUP_DEPLOYMENT_NAME" "$BACKUP_HELM_CHART" "config.yaml"
  install_rc=$?

  if [[ $install_rc -ne 0 ]]; then
    echo "Backup container install FAILED (see above for details)."
    exit 1
  fi

  oc set image deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME backup-storage=$DB_BACKUP_IMAGE
  rm config.yaml
fi
