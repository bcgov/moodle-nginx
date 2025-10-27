# Source the utility script
source ./openshift/scripts/_utils.sh

helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update

log_info "Deploying database backups to: $DB_BACKUP_DEPLOYMENT_NAME..."

# Ensure backup storage secrets are managed properly before Helm deployment
log_info "🔍 Pre-deployment secret management..."

# Use the webhook URL from environment variable (set by GitHub Actions)
# This avoids exposing the webhook URL in the repository
webhook_url="${ROCKETCHAT_WEBHOOK_URL:-}"

if [[ -z "$webhook_url" ]]; then
  log_warn "⚠️  ROCKETCHAT_WEBHOOK_URL environment variable not set"
fi

# Remove any existing secret that might conflict with Helm management
if oc get secret moodle-db-backup-storage-secrets &> /dev/null; then
  log_info "🔧 Removing existing secret to allow proper management..."
  if oc delete secret moodle-db-backup-storage-secrets; then
    log_info "✅ Removed existing secret (moodle-db-backup-storage-secrets)"
  else
    log_error "❌ Failed to remove existing secret"
    exit 1
  fi
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

log_info "🔍 Verifying generated files..."
if [[ -f "backup-values.yaml" ]]; then
  log_info "✅ backup-values.yaml created successfully"
  log_debug "📁 File details:"
  ls -la backup-values.yaml
  log_debug "📋 File contents:"
  cat backup-values.yaml
else
  log_error "❌ backup-values.yaml was not created"
  exit 1
fi

log_info "📋 Generated backup-values.yaml content (environment variables section):"
log_debug "--- Environment Variables ---"
grep -A 10 "env:" backup-values.yaml || log_warn "No env section found"
log_debug "--- End Environment Variables ---"

# Backup the values file to prevent accidental deletion
log_info "🔒 Creating backup copy of values file..."
cp backup-values.yaml backup-values-copy.yaml

# Use the utility function for upgrade
log_info "🚀 Calling create_or_update_helm_deployment..."
create_or_update_helm_deployment "$DB_BACKUP_DEPLOYMENT_NAME" "$BACKUP_HELM_CHART" "backup-values.yaml" "backup-values.yaml"
upgrade_rc=$?

log_debug "📊 Post-Helm deployment file status:"
log_debug "backup-values.yaml exists: $(if [[ -f "backup-values.yaml" ]]; then echo "YES"; else echo "NO"; fi)"
log_debug "backup-values-copy.yaml exists: $(if [[ -f "backup-values-copy.yaml" ]]; then echo "YES"; else echo "NO"; fi)"

if [[ $upgrade_rc -ne 0 ]]; then
  log_error "Backup container update FAILED (see above for details)."
  exit 1
fi

# Ensure backup storage secrets are properly configured after Helm deployment
log_info "🔍 Managing backup storage secrets after Helm deployment..."

# Validate webhook URL parameter
if [[ -z "$webhook_url" ]]; then
  log_warn "⚠️  No webhook URL provided - secret will have empty webhook-url"
  webhook_url=""
fi

# Define the specific secret values for backup storage
# These are the key/value pairs required for the backup storage secret
backup_secret_values="ftp-password=,ftp-url=,ftp-user=,mssql-sa-password=,webhook-url=${webhook_url}"

# Use the utility function to manage secrets with validation
manage_backup_storage_secrets "$DEPLOY_NAMESPACE" "moodle-db-backup-storage-secrets" "$backup_secret_values" "webhook-url" "backup storage secrets"
secret_result=$?

if [[ $secret_result -eq 0 ]]; then
  log_info "✅ Backup storage secrets are properly configured (no changes made)"
elif [[ $secret_result -eq 2 ]]; then
  log_info "✅ Backup storage secrets are properly configured (changes made)"
  log_info "🔄 Secret changes detected - deployment restart will be needed"
  DEPLOYMENT_RESTART_NEEDED=true
else
  log_error "❌ Failed to configure backup storage secrets"
  exit 1
fi

# Debug: Check what values Helm is actually using
log_debug "🔍 Checking Helm values for environment variables..."
log_debug "📋 Current Helm deployment status:"
helm status "$DB_BACKUP_DEPLOYMENT_NAME" --output yaml 2>/dev/null || log_debug "No existing deployment found"

log_debug "📋 Current Helm values (all values):"
helm get values "$DB_BACKUP_DEPLOYMENT_NAME" --all 2>/dev/null || log_debug "No values found"

if helm get values "$DB_BACKUP_DEPLOYMENT_NAME" | grep -A 10 "env:" &>/dev/null; then
  log_debug "📋 Current Helm values (env section):"
  helm get values "$DB_BACKUP_DEPLOYMENT_NAME" | grep -A 15 "env:" | head -20
else
  log_warn "⚠️  No env section found in Helm values"
fi

log_debug "🔍 Checking if backup values file still exists after Helm operations..."
if [[ -f "backup-values.yaml" ]]; then
  log_info "✅ backup-values.yaml still exists"
elif [[ -f "backup-values-copy.yaml" ]]; then
  log_warn "⚠️  backup-values.yaml missing but backup copy exists - restoring..."
  cp backup-values-copy.yaml backup-values.yaml
else
  log_error "❌ Both backup-values.yaml and backup copy are missing!"
fi

if [[ `oc describe deployment $DB_BACKUP_DEPLOYMENT_FULL_NAME 2>&1` =~ "NotFound" ]]; then
  log_error "Backup Helm exists, but deployment NOT FOUND."
  exit 1
else
  log_info "Backup deployment FOUND. Updating image..."
  oc set image deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME backup-storage=$DB_BACKUP_IMAGE

  log_debug "🔍 Checking deployment configuration for environment variables..."
  log_debug "📋 Deployment environment variables:"
  oc get deployment "$DB_BACKUP_DEPLOYMENT_FULL_NAME" -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.' 2>/dev/null || log_warn "Failed to get environment variables from deployment"

  log_debug "📋 Deployment environment variables (alternative method):"
  oc describe deployment "$DB_BACKUP_DEPLOYMENT_FULL_NAME" | grep -A 20 "Environment:" || log_warn "No environment section found in deployment"
fi

# Verify deployment and troubleshoot if needed
log_info "🔍 Verifying backup storage deployment..."
if ! wait_for "deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME" "ready" "300s"; then
  log_warn "⚠️  Backup storage deployment not ready. Checking for issues..."

  # Get pod status and events
  log_debug "📋 Pod status:"
  oc get pods -l app.kubernetes.io/name=backup-storage

  log_debug "📋 Recent events:"
  oc get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' | tail -10

  log_debug "📋 Checking required secrets:"
  log_debug "🔍 Backup storage secrets:"
  oc get secret moodle-db-backup-storage-secrets || log_warn "❌ Backup storage secrets missing"

  log_debug "🔍 Database secrets:"
  if oc get secret moodle-secrets &> /dev/null; then
    log_info "✅ Database secrets exist"
    # Check if the required keys exist
    if oc get secret moodle-secrets -o jsonpath='{.data.database-user}' &> /dev/null; then
      log_info "  ✅ database-user key found"
    else
      log_warn "  ❌ database-user key missing from moodle-secrets"
    fi
    if oc get secret moodle-secrets -o jsonpath='{.data.database-password}' &> /dev/null; then
      log_info "  ✅ database-password key found"
    else
      log_warn "  ❌ database-password key missing from moodle-secrets"
    fi
  else
    log_error "❌ Database secrets missing"
  fi

  log_warn "⚠️  Backup storage deployment has issues, but continuing..."
else
  log_info "✅ Backup storage deployment is ready"

  # Verify that the environment variables are properly set
  log_debug "🔍 Verifying database credentials configuration..."
  backup_pod=$(oc get pods -l app.kubernetes.io/name=backup-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -n "$backup_pod" ]]; then
    log_debug "  📋 Checking environment variables in pod: $backup_pod"

    # Check if MARIADB_GALERA_USER is set
    if oc exec "$backup_pod" -- printenv MARIADB_GALERA_USER &>/dev/null; then
      db_user=$(oc exec "$backup_pod" -- printenv MARIADB_GALERA_USER 2>/dev/null)
      if [[ -n "$db_user" ]]; then
        log_info "  ✅ MARIADB_GALERA_USER is set (value: ${db_user})"
      else
        log_warn "  ⚠️  MARIADB_GALERA_USER is empty"
      fi
    else
      log_error "  ❌ MARIADB_GALERA_USER environment variable not found"
    fi

    # Check if MARIADB_GALERA_PASSWORD is set (don't print the value)
    if oc exec "$backup_pod" -- printenv MARIADB_GALERA_PASSWORD &>/dev/null; then
      db_password=$(oc exec "$backup_pod" -- printenv MARIADB_GALERA_PASSWORD 2>/dev/null)
      if [[ -n "$db_password" ]]; then
        log_info "  ✅ MARIADB_GALERA_PASSWORD is set"
      else
        log_warn "  ⚠️  MARIADB_GALERA_PASSWORD is empty"
      fi
    else
      log_error "  ❌ MARIADB_GALERA_PASSWORD environment variable not found"
    fi
  else
    log_warn "  ⚠️  Could not find backup pod to verify environment variables"
  fi
fi

# Handle deployment restart if secret changes were made
if [[ "${DEPLOYMENT_RESTART_NEEDED:-false}" == "true" ]]; then
  log_info ""
  restart_deployment "$DB_BACKUP_DEPLOYMENT_FULL_NAME" "$DEPLOY_NAMESPACE"
  restart_result=$?

  if [[ $restart_result -eq 0 ]]; then
    log_info "✅ Deployment successfully restarted to pick up secret changes"
  elif [[ $restart_result -eq 2 ]]; then
    log_warn "⚠️  Deployment restart timed out, but was initiated"
  else
    log_warn "⚠️  Deployment restart failed, but continuing..."
  fi
fi

log_info "Backup container deployment completed."
