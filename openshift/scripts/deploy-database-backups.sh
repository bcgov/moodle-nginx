helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update

echo "Deploying database backups to: $DB_BACKUP_DEPLOYMENT_NAME..."

# Check if the Helm deployment exists
if helm list -q | grep -q "^$DB_BACKUP_DEPLOYMENT_NAME$"; then
  echo "Helm deployment FOUND. Updating..."
  if [[ `helm upgrade $DB_BACKUP_DEPLOYMENT_NAME $BACKUP_HELM_CHART --atomic --wait --timeout 30 --reuse-values 2>&1` =~ "Error" ]]; then
    echo "Backup container update FAILED."
    exit 1
  fi

  if [[ `oc describe deployment $DB_BACKUP_DEPLOYMENT_FULL_NAME 2>&1` =~ "NotFound" ]]; then
    echo "Backup Helm exists, but deployment NOT FOUND."

    # echo "Attempt to fix deploymment..."
    oc annotate --overwrite  dc/${{ env.WEB_DEPLOYMENT_NAME  }} kubectl.kubernetes.io/restartedAt=`date +%FT%T` -n ${{ env.OPENSHIFT_DEPLOY_PROJECT }}-${{ github.ref_name }}

  else
    echo "Backup deployment FOUND. Updating..."
    oc set image deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME backup-storage=$DB_BACKUP_IMAGE
  fi

  echo "Backup container updates completed."
else
  echo "Helm $DB_BACKUP_DEPLOYMENT_NAME NOT FOUND. Beginning deployment..."
  echo "
    image:
      repository: \"$BACKUP_HELM_CHART\"
      pullPolicy: Always
      tag: dev

    persistence:
      backup:
        accessMode: ReadWriteMany
        storageClassName: netapp-file-backup
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
  helm install $DB_BACKUP_DEPLOYMENT_NAME $BACKUP_HELM_CHART --atomic --wait --timeout 30 -f config.yaml
  oc set image deployment/$DB_BACKUP_DEPLOYMENT_NAME backup-storage=$DB_BACKUP_IMAGE
fi
