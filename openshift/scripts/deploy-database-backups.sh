helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update
if [[ `oc describe deployment $DB_BACKUP_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "Backup deployment NOT FOUND. Begin backup container deployment..."
  echo "
    image:
      repository: \"$BACKUP_HELM_CHART\"
      pullPolicy: Always
      tag: dev

    persistence:
      verification:
        storageClassName: netapp-file-backup

    backupConfig: |
      mariadb=\"$DB_HOST/$DB_NAME\"

      0 1 * * * default ./backup.sh -s
      0 4 * * * default ./backup.sh -s -v all

    db:
      secretName: moodle-secrets
      usernameKey: database-user
      passwordKey: database-password

    env:
      DATABASE_SERVICE_NAME:
        value: \"$DB_HOST\"
      ENVIRONMENT_FRIENDLY_NAME:
        value: \"DB Backups\"
    " > config.yaml
  helm install $DB_BACKUP_DEPLOYMENT_NAME $BACKUP_HELM_CHART -f config.yaml
  oc set image deployment/$DB_BACKUP_DEPLOYMENT_NAME backup-storage=$DB_BACKUP_IMAGE
else
  echo "Backup container installation FOUND. Updating..."
  if [[ `helm upgrade moodle-db $BACKUP_HELM_CHART --reuse-values 2>&1` =~ "Error" ]]; then
    echo "Backup container update FAILED."
    exit 1
  fi
  oc set image deployment/$DB_BACKUP_DEPLOYMENT_NAME-backup-storage backup-storage=$DB_BACKUP_IMAGE
  echo "Backup container updates completed."
fi