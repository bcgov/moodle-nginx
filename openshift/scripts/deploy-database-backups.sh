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

# Generate comprehensive values file for both install and upgrade
cat <<EOF > backup-values.yaml
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
  MARIADB_GALERA_USER:
    valueFrom:
      secretKeyRef:
        name: moodle-secrets
        key: database-user
  MARIADB_GALERA_PASSWORD:
    valueFrom:
      secretKeyRef:
        name: moodle-secrets
        key: database-password
EOF

echo "🔍 Verifying generated files..."
if [[ -f "backup-values.yaml" ]]; then
  echo "✅ backup-values.yaml created successfully"
else
  echo "❌ backup-values.yaml was not created"
  exit 1
fi

echo "📋 Generated backup-values.yaml content (environment variables section):"
echo "--- Environment Variables ---"
grep -A 10 "env:" backup-values.yaml || echo "No env section found"
echo "--- End Environment Variables ---"

# Use the utility function for upgrade
create_or_update_helm_deployment "$DB_BACKUP_DEPLOYMENT_NAME" "$BACKUP_HELM_CHART" "backup-values.yaml" "backup-values.yaml"
upgrade_rc=$?

if [[ $upgrade_rc -ne 0 ]]; then
  echo "Backup container update FAILED (see above for details)."
  exit 1
fi

# Debug: Check what values Helm is actually using
echo "🔍 Checking Helm values for environment variables..."
if helm get values "$DB_BACKUP_DEPLOYMENT_NAME" | grep -A 10 "env:" &>/dev/null; then
  echo "📋 Current Helm values (env section):"
  helm get values "$DB_BACKUP_DEPLOYMENT_NAME" | grep -A 15 "env:" | head -20
else
  echo "⚠️  No env section found in Helm values"
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
  echo "🔍 Backup storage secrets:"
  oc get secret moodle-db-backup-storage-secrets || echo "❌ Backup storage secrets missing"

  echo "🔍 Database secrets:"
  if oc get secret moodle-secrets &> /dev/null; then
    echo "✅ Database secrets exist"
    # Check if the required keys exist
    if oc get secret moodle-secrets -o jsonpath='{.data.database-user}' &> /dev/null; then
      echo "  ✅ database-user key found"
    else
      echo "  ❌ database-user key missing from moodle-secrets"
    fi
    if oc get secret moodle-secrets -o jsonpath='{.data.database-password}' &> /dev/null; then
      echo "  ✅ database-password key found"
    else
      echo "  ❌ database-password key missing from moodle-secrets"
    fi
  else
    echo "❌ Database secrets missing"
  fi

  echo "⚠️  Backup storage deployment has issues, but continuing..."
else
  echo "✅ Backup storage deployment is ready"

  # Verify that the environment variables are properly set
  echo "🔍 Verifying database credentials configuration..."
  backup_pod=$(oc get pods -l app.kubernetes.io/name=backup-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -n "$backup_pod" ]]; then
    echo "  📋 Checking environment variables in pod: $backup_pod"

    # Check if MARIADB_GALERA_USER is set
    if oc exec "$backup_pod" -- printenv MARIADB_GALERA_USER &>/dev/null; then
      db_user=$(oc exec "$backup_pod" -- printenv MARIADB_GALERA_USER 2>/dev/null)
      if [[ -n "$db_user" ]]; then
        echo "  ✅ MARIADB_GALERA_USER is set (value: ${db_user})"
      else
        echo "  ⚠️  MARIADB_GALERA_USER is empty"
      fi
    else
      echo "  ❌ MARIADB_GALERA_USER environment variable not found"
    fi

    # Check if MARIADB_GALERA_PASSWORD is set (don't print the value)
    if oc exec "$backup_pod" -- printenv MARIADB_GALERA_PASSWORD &>/dev/null; then
      db_password=$(oc exec "$backup_pod" -- printenv MARIADB_GALERA_PASSWORD 2>/dev/null)
      if [[ -n "$db_password" ]]; then
        echo "  ✅ MARIADB_GALERA_PASSWORD is set (length: ${#db_password} chars)"
      else
        echo "  ⚠️  MARIADB_GALERA_PASSWORD is empty"
      fi
    else
      echo "  ❌ MARIADB_GALERA_PASSWORD environment variable not found"
    fi
  else
    echo "  ⚠️  Could not find backup pod to verify environment variables"
  fi
fi

echo "Backup container deployment completed."
