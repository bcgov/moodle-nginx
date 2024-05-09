helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update
if [[ `oc describe deployment ${{ inputs.DB_BACKUP_DEPLOYMENT_NAME }} 2>&1` =~ "NotFound" ]]; then
  echo "Backup deployment NOT FOUND. Begin backup container deployment..."
  echo '
    image:
      repository: ${{ inputs.BACKUP_HELM_CHART }}
      pullPolicy: Always
      tag: dev

    backupConfig: |
      mariadb=db/moodle

      0 1 * * * default ./backup.sh -s
      0 4 * * * default ./backup.sh -s -v all

    db:
      secretName: moodle-secrets
      usernameKey: database-user
      passwordKey: database-password

    env:
      DATABASE_SERVICE_NAME:
        value: db
      ENVIRONMENT_FRIENDLY_NAME:
        value: "DB Backups"
    ' > config.yaml
  helm install ${{ inputs.DB_BACKUP_DEPLOYMENT_NAME }} ${{ inputs.BACKUP_HELM_CHART }} -f config.yaml
  oc set image deployment/${{ inputs.DB_BACKUP_DEPLOYMENT_NAME }} backup-storage=bcgovimages/backup-container-mariadb
else
  echo "Backup container installation FOUND. Updating..."
  if [[ `helm upgrade moodle-db ${{ inputs.BACKUP_HELM_CHART }} --reuse-values 2>&1` =~ "Error" ]]; then
    echo "Backup container update FAILED."
    exit 1
  fi
  oc set image deployment/moodle-db-backup-storage backup-storage=bcgovimages/backup-container-mariadb
  echo "Backup container updates completed."
fi