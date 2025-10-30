# Source the utility script
source ./openshift/scripts/_utils.sh
source ./openshift/scripts/helm-image-resolver.sh

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

helm repo add bcgov http://bcgov.github.io/helm-charts
helm repo update

log_info "Deploying database backups to: $DB_BACKUP_DEPLOYMENT_NAME..."

# Resolve backup image configuration with Artifactory support
if [ "${USE_ARTIFACTORY:-false}" = "true" ]; then
    RESOLVED_BACKUP_IMAGE="$ARTIFACTORY_REGISTRY/$BCGOV_REGISTRY/$BACKUP_IMAGE"
    log_info "🏭 Using Artifactory backup image: $RESOLVED_BACKUP_IMAGE"
else
    RESOLVED_BACKUP_IMAGE="$BCGOV_REGISTRY/$BACKUP_IMAGE"
    log_info "🐳 Using upstream backup image: $RESOLVED_BACKUP_IMAGE"
fi

# Ensure backup storage secrets are managed properly before Helm deployment
log_info "🔍 Pre-deployment secret management..."

# Validate environment-specific database secrets before proceeding
log_info "🔍 Validating environment-specific database configuration..."
if oc get secret moodle-secrets &> /dev/null; then
  # Verify the database connection details match the current environment
  db_user_from_secret=$(oc get secret moodle-secrets -o jsonpath='{.data.database-user}' | base64 -d 2>/dev/null || echo "")
  if [[ -n "$db_user_from_secret" ]]; then
    log_info "Database user configured for this environment: $db_user_from_secret"
    # Validate the user matches expected pattern for environment
    if [[ "$db_user_from_secret" =~ ^[a-zA-Z0-9_-]+$ ]]; then
      log_info "Database user format validation passed"
    else
      log_warn "Database user format may be unusual: $db_user_from_secret"
    fi
  else
    log_error "Database user not found in moodle-secrets"
    exit 1
  fi

  # Verify database host matches the configured environment
  log_info "Database host configured: $DB_HOST"
  log_info "Database name configured: $DB_NAME"
  log_info "📋 This deployment will configure backups for: $db_user_from_secret@$DB_HOST/$DB_NAME"
else
  log_error "Required moodle-secrets not found in this environment"
  log_error "   Cannot proceed with backup deployment without database credentials"
  exit 1
fi

# Use the webhook URL from environment variable (set by GitHub Actions)
# This avoids exposing the webhook URL in the repository
webhook_url="${ROCKETCHAT_WEBHOOK_URL:-}"

if [[ -z "$webhook_url" ]]; then
  log_warn "ROCKETCHAT_WEBHOOK_URL environment variable not set"
fi

# Remove any existing secret that might conflict with Helm management
if oc get secret moodle-db-backup-storage-secrets &> /dev/null; then
  log_info "🔧 Removing existing secret to allow proper management..."
  if oc delete secret moodle-db-backup-storage-secrets; then
    log_info "Removed existing secret (moodle-db-backup-storage-secrets)"
  else
    log_error "Failed to remove existing secret"
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
    # Ensure PVC is NEVER deleted during upgrades
    annotations:
      "helm.sh/resource-policy": keep
  verification:
    storageClassName: netapp-file-standard
    # Ensure PVC is NEVER deleted during upgrades
    annotations:
      "helm.sh/resource-policy": keep

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

log_info "🔍 Verifying generated files..."
if [[ -f "backup-values.yaml" ]]; then
  log_info "backup-values.yaml created successfully"
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    log_debug "📁 File details:"
    ls -la backup-values.yaml
    log_debug "📋 File contents:"
    cat backup-values.yaml
  fi
else
  log_error "backup-values.yaml was not created"
  exit 1
fi

if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
  log_info "📋 Generated backup-values.yaml content (environment variables section):"
  log_debug "--- Environment Variables ---"
  grep -A 10 "env:" backup-values.yaml || log_warn "No env section found"
  log_debug "--- End Environment Variables ---"
fi

# Backup the values file to prevent accidental deletion
log_info "🔒 Creating backup copy of values file..."
cp backup-values.yaml backup-values-copy.yaml

# Pre-deployment PVC verification for data protection
log_info "🔍 Pre-deployment PVC verification..."
backup_pvc_name="${DB_BACKUP_DEPLOYMENT_NAME}-backup-storage-backup-pvc"
verification_pvc_name="${DB_BACKUP_DEPLOYMENT_NAME}-backup-storage-verification-pvc"

if oc get pvc "$backup_pvc_name" &> /dev/null; then
  backup_pvc_size=$(oc get pvc "$backup_pvc_name" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
  backup_pvc_status=$(oc get pvc "$backup_pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null)
  log_info "Existing backup PVC found: $backup_pvc_name (${backup_pvc_size}, ${backup_pvc_status})"

  # Check if PVC contains data
  if [[ "$backup_pvc_status" == "Bound" ]]; then
    log_info "Backup PVC is bound and ready - existing backup data will be preserved"
  else
    log_warn "Backup PVC status: $backup_pvc_status - may need attention"
  fi
else
  log_info "📋 No existing backup PVC found - new PVC will be created"
fi

if oc get pvc "$verification_pvc_name" &> /dev/null; then
  verification_pvc_size=$(oc get pvc "$verification_pvc_name" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
  verification_pvc_status=$(oc get pvc "$verification_pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null)
  log_info "Existing verification PVC found: $verification_pvc_name (${verification_pvc_size}, ${verification_pvc_status})"
else
  log_info "📋 No existing verification PVC found - new PVC will be created"
fi

# Use the utility function for upgrade
log_info "🚀 Calling create_or_update_helm_deployment..."
create_or_update_helm_deployment "$DB_BACKUP_DEPLOYMENT_NAME" "$BACKUP_HELM_CHART" "backup-values.yaml" "backup-values.yaml"
upgrade_rc=$?

if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
  log_debug "📊 Post-Helm deployment file status:"
  log_debug "backup-values.yaml exists: $(if [[ -f "backup-values.yaml" ]]; then echo "YES"; else echo "NO"; fi)"
  log_debug "backup-values-copy.yaml exists: $(if [[ -f "backup-values-copy.yaml" ]]; then echo "YES"; else echo "NO"; fi)"
fi

if [[ $upgrade_rc -ne 0 ]]; then
  log_error "Backup container update FAILED (see above for details)."
  exit 1
fi

# Ensure backup storage secrets are properly configured after Helm deployment
log_info "🔍 Managing backup storage secrets after Helm deployment..."

# Validate webhook URL parameter
if [[ -z "$webhook_url" ]]; then
  log_warn "No webhook URL provided - secret will have empty webhook-url"
  webhook_url=""
fi

# Define the specific secret values for backup storage
# These are the key/value pairs required for the backup storage secret
backup_secret_values="ftp-password=,ftp-url=,ftp-user=,mssql-sa-password=,webhook-url=${webhook_url}"

# Use the utility function to manage secrets with validation
manage_backup_storage_secrets "$DEPLOY_NAMESPACE" "moodle-db-backup-storage-secrets" "$backup_secret_values" "webhook-url" "backup storage secrets"
secret_result=$?

if [[ $secret_result -eq 0 ]]; then
  log_info "Backup storage secrets are properly configured (no changes made)"
elif [[ $secret_result -eq 2 ]]; then
  log_info "Backup storage secrets are properly configured (changes made)"
  log_info "🔄 Secret changes detected - deployment restart will be needed"
  DEPLOYMENT_RESTART_NEEDED=true
else
  log_error "Failed to configure backup storage secrets"
  exit 1
fi

# Debug: Check what values Helm is actually using
if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
  log_debug "🔍 Checking Helm values for environment variables..."
  log_debug "📋 Current Helm deployment status:"
  helm status "$DB_BACKUP_DEPLOYMENT_NAME" --output yaml 2>/dev/null || log_debug "No existing deployment found"

  log_debug "📋 Current Helm values (all values):"
  helm get values "$DB_BACKUP_DEPLOYMENT_NAME" --all 2>/dev/null || log_debug "No values found"

  if helm get values "$DB_BACKUP_DEPLOYMENT_NAME" | grep -A 10 "env:" &>/dev/null; then
    log_debug "📋 Current Helm values (env section):"
    helm get values "$DB_BACKUP_DEPLOYMENT_NAME" | grep -A 15 "env:" | head -20
  else
    log_warn "No env section found in Helm values"
  fi
fi

log_debug "🔍 Checking if backup values file still exists after Helm operations..."
if [[ -f "backup-values.yaml" ]]; then
  log_info "backup-values.yaml still exists"
elif [[ -f "backup-values-copy.yaml" ]]; then
  log_warn "backup-values.yaml missing but backup copy exists - restoring..."
  cp backup-values-copy.yaml backup-values.yaml
else
  log_error "Both backup-values.yaml and backup copy are missing!"
fi

if [[ `oc describe deployment $DB_BACKUP_DEPLOYMENT_FULL_NAME 2>&1` =~ "NotFound" ]]; then
  log_error "Backup Helm exists, but deployment NOT FOUND."
  exit 1
else
  log_info "Backup deployment FOUND. Updating image..."
  oc set image deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME backup-storage=$RESOLVED_BACKUP_IMAGE

  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    log_debug "🔍 Checking deployment configuration for environment variables..."
    log_debug "📋 Deployment environment variables:"
    oc get deployment "$DB_BACKUP_DEPLOYMENT_FULL_NAME" -o jsonpath='{.spec.template.spec.containers[0].env}' | jq '.' 2>/dev/null || log_warn "Failed to get environment variables from deployment"

    log_debug "📋 Deployment environment variables (alternative method):"
    oc describe deployment "$DB_BACKUP_DEPLOYMENT_FULL_NAME" | grep -A 20 "Environment:" || log_warn "No environment section found in deployment"
  fi
fi

# Verify deployment and troubleshoot if needed
log_info "🔍 Verifying backup storage deployment..."
if ! wait_for "deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME" "ready" "300s"; then
  log_warn "Backup storage deployment not ready. Checking for issues..."

  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    # Get pod status and events
    log_debug "📋 Pod status:"
    oc get pods -l app.kubernetes.io/name=backup-storage

    log_debug "📋 Recent events:"
    oc get events --field-selector involvedObject.kind=Pod --sort-by='.lastTimestamp' | tail -10

    log_debug "📋 Checking required secrets:"
    log_debug "🔍 Backup storage secrets:"
    oc get secret moodle-db-backup-storage-secrets || log_warn "Backup storage secrets missing"
  fi

  log_debug "🔍 Database secrets:"
  if oc get secret moodle-secrets &> /dev/null; then
    log_info "Database secrets exist"
    # Check if the required keys exist
    if oc get secret moodle-secrets -o jsonpath='{.data.database-user}' &> /dev/null; then
      log_info "  database-user key found"
      if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
        # Decode and verify the database user for environment validation
        decoded_user=$(oc get secret moodle-secrets -o jsonpath='{.data.database-user}' | base64 -d 2>/dev/null || echo "")
        if [[ -n "$decoded_user" ]]; then
          log_debug "  📋 Database user configured: $decoded_user"
          # Check if this matches expected environment pattern
          if [[ "$decoded_user" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_info "  Database user format is valid"
          else
            log_warn "Database user format may be invalid: $decoded_user"
          fi
        else
          log_warn "  Database user is empty or invalid base64"
        fi
      fi
    else
      log_warn "  database-user key missing from moodle-secrets"
    fi
    if oc get secret moodle-secrets -o jsonpath='{.data.database-password}' &> /dev/null; then
      log_info "  database-password key found"
      if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
        # Verify password exists (don't decode for security)
        password_length=$(oc get secret moodle-secrets -o jsonpath='{.data.database-password}' | wc -c)
        if [[ $password_length -gt 10 ]]; then
          log_info "  Database password appears to be set (${password_length} chars encoded)"
        else
          log_warn "  Database password appears to be empty or very short"
        fi
      fi
    else
      log_warn "  database-password key missing from moodle-secrets"
    fi
  else
    log_error "Database secrets missing"
  fi

  log_warn "Backup storage deployment has issues, but continuing..."
else
  log_info "Backup storage deployment is ready"

  # Post-deployment PVC verification for data integrity
  log_info "🔍 Post-deployment PVC verification..."

  if oc get pvc "$backup_pvc_name" &> /dev/null; then
    backup_pvc_size_after=$(oc get pvc "$backup_pvc_name" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
    backup_pvc_status_after=$(oc get pvc "$backup_pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null)
    log_info "Backup PVC after deployment: $backup_pvc_name (${backup_pvc_size_after}, ${backup_pvc_status_after})"

    if [[ "$backup_pvc_status_after" == "Bound" ]]; then
      log_info "Backup PVC is properly bound - backup data preserved successfully"
    else
      log_warn "Backup PVC status after deployment: $backup_pvc_status_after"
    fi
  else
    log_error "Backup PVC not found after deployment - this should not happen!"
  fi

  if oc get pvc "$verification_pvc_name" &> /dev/null; then
    verification_pvc_size_after=$(oc get pvc "$verification_pvc_name" -o jsonpath='{.spec.resources.requests.storage}' 2>/dev/null)
    verification_pvc_status_after=$(oc get pvc "$verification_pvc_name" -o jsonpath='{.status.phase}' 2>/dev/null)
    log_info "Verification PVC after deployment: $verification_pvc_name (${verification_pvc_size_after}, ${verification_pvc_status_after})"
  else
    log_error "Verification PVC not found after deployment - this should not happen!"
  fi

  # Verify that the environment variables are properly set
  log_debug "🔍 Verifying database credentials configuration..."
  backup_pod=$(oc get pods -l app.kubernetes.io/name=backup-storage -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -n "$backup_pod" ]]; then
    if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
      log_debug "  📋 Checking environment variables in pod: $backup_pod"
    fi

    # Get expected values from secrets for cross-environment validation
    expected_user=$(oc get secret moodle-secrets -o jsonpath='{.data.database-user}' | base64 -d 2>/dev/null || echo "")
    expected_password_encoded=$(oc get secret moodle-secrets -o jsonpath='{.data.database-password}' 2>/dev/null || echo "")

    # Check if DATABASE_USER is set and matches the secret
    if oc exec "$backup_pod" -- printenv DATABASE_USER &>/dev/null; then
      actual_user=$(oc exec "$backup_pod" -- printenv DATABASE_USER 2>/dev/null)
      if [[ -n "$actual_user" ]]; then
        if [[ "$actual_user" == "$expected_user" ]]; then
          log_info "  DATABASE_USER is correctly set and matches secret (value: ${actual_user})"
        else
          log_warn "  DATABASE_USER mismatch - Pod: '$actual_user', Secret: '$expected_user'"
          log_warn "     This may indicate environment configuration drift - redeployment may be needed"
          DEPLOYMENT_RESTART_NEEDED=true
        fi
      else
        log_warn "  DATABASE_USER is empty"
        DEPLOYMENT_RESTART_NEEDED=true
      fi
    else
      log_error "  DATABASE_USER environment variable not found"
      DEPLOYMENT_RESTART_NEEDED=true
    fi

    # Check if DATABASE_PASSWORD is set and matches the secret (compare lengths for security)
    if oc exec "$backup_pod" -- printenv DATABASE_PASSWORD &>/dev/null; then
      actual_password=$(oc exec "$backup_pod" -- printenv DATABASE_PASSWORD 2>/dev/null)
      if [[ -n "$actual_password" ]]; then
        expected_password=$(echo "$expected_password_encoded" | base64 -d 2>/dev/null || echo "")
        if [[ -n "$expected_password" && "$actual_password" == "$expected_password" ]]; then
          log_info "  DATABASE_PASSWORD is correctly set and matches secret"
        elif [[ -n "$expected_password" ]]; then
          log_warn "  DATABASE_PASSWORD mismatch detected (lengths: pod=${#actual_password}, secret=${#expected_password})"
          log_warn "     This may indicate environment configuration drift - redeployment may be needed"
          DEPLOYMENT_RESTART_NEEDED=true
        else
          log_warn "  Could not verify DATABASE_PASSWORD - secret may be invalid"
          DEPLOYMENT_RESTART_NEEDED=true
        fi
      else
        log_warn "  DATABASE_PASSWORD is empty"
        DEPLOYMENT_RESTART_NEEDED=true
      fi
    else
      log_error "  DATABASE_PASSWORD environment variable not found"
      DEPLOYMENT_RESTART_NEEDED=true
    fi

    # Also check the legacy MARIADB_GALERA_* variables for backwards compatibility (only in debug mode)
    if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
      log_debug "  📋 Checking legacy MARIADB_GALERA_* variables..."
      if oc exec "$backup_pod" -- printenv MARIADB_GALERA_USER &>/dev/null; then
        legacy_user=$(oc exec "$backup_pod" -- printenv MARIADB_GALERA_USER 2>/dev/null)
        if [[ -n "$legacy_user" ]]; then
          log_debug "  MARIADB_GALERA_USER is set (value: ${legacy_user})"
          # If legacy vars are set, verify they match too
          if [[ "$legacy_user" != "$expected_user" ]]; then
            log_warn "  MARIADB_GALERA_USER mismatch - may need redeployment"
            DEPLOYMENT_RESTART_NEEDED=true
          fi
        else
          log_debug "  MARIADB_GALERA_USER is empty (this is expected with chart-managed credentials)"
        fi
      else
        log_debug "  MARIADB_GALERA_USER environment variable not found (this is expected with chart-managed credentials)"
      fi

      if oc exec "$backup_pod" -- printenv MARIADB_GALERA_PASSWORD &>/dev/null; then
        legacy_password=$(oc exec "$backup_pod" -- printenv MARIADB_GALERA_PASSWORD 2>/dev/null)
        if [[ -n "$legacy_password" ]]; then
          log_debug "  MARIADB_GALERA_PASSWORD is set"
          # Verify legacy password matches if it's set
          expected_password=$(echo "$expected_password_encoded" | base64 -d 2>/dev/null || echo "")
          if [[ -n "$expected_password" && "$legacy_password" != "$expected_password" ]]; then
            log_warn "  MARIADB_GALERA_PASSWORD mismatch - may need redeployment"
            DEPLOYMENT_RESTART_NEEDED=true
          fi
        else
          log_debug "  MARIADB_GALERA_PASSWORD is empty (this is expected with chart-managed credentials)"
        fi
      else
        log_debug "  MARIADB_GALERA_PASSWORD environment variable not found (this is expected with chart-managed credentials)"
      fi
    fi

    # Environment-specific validation summary
    if [[ "${DEPLOYMENT_RESTART_NEEDED:-false}" == "true" ]]; then
      log_warn "  Environment variable mismatches detected - deployment restart will be triggered"
      log_info "     This ensures the backup container uses current environment credentials"
    else
      log_info "  All database credentials are properly configured and match the environment"
    fi
  else
    log_warn "  Could not find backup pod to verify environment variables"
  fi
fi

# Handle deployment restart if secret changes were made
if [[ "${DEPLOYMENT_RESTART_NEEDED:-false}" == "true" ]]; then
  log_info ""
  restart_deployment "$DB_BACKUP_DEPLOYMENT_FULL_NAME" "$DEPLOY_NAMESPACE"
  restart_result=$?

  if [[ $restart_result -eq 0 ]]; then
    log_info "Deployment successfully restarted to pick up secret changes"
  elif [[ $restart_result -eq 2 ]]; then
    log_warn "Deployment restart timed out, but was initiated"
  else
    log_warn "Deployment restart failed, but continuing..."
  fi
fi

log_info "Backup container deployment completed."
