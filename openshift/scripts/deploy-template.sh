#!/bin/bash
#set -e # Exit on error

# Universal _utils.sh loader - works in all environments
# Priority: same-dir > /scripts > /usr/local/bin > ./openshift/scripts
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

# Initialize utility file arrays and show debug output
# This ensures we always have the complete and up-to-date list of utility files
initialize_utility_arrays

test -n $DEPLOY_NAMESPACE
oc project $DEPLOY_NAMESPACE
log_info "Current namespace is $DEPLOY_NAMESPACE"

# Enable Moodle maintenance mode
manage_maintenance_mode "enable" "maintenance-message"

# Ensure secrets are linked for pulling from Artifactory
oc secrets link default "${ARTIFACTORY_PULL_SECRET:-artifactory-m950-learning}" --for=pull

# Scale [down] php to 0 replicas
scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "0" "0"
if ! wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "120s" "down"; then
  log_error "Failed to scale $PHP_DEPLOYMENT_NAME to 0 replicas. Exiting..."
  exit 1
fi

# Scale [down] web to 0 replicas
scale_deployment "deployment" "$WEB_DEPLOYMENT_NAME" "0" "0"
if ! wait_for "deployment/$WEB_DEPLOYMENT_NAME" "ready" "600s" "down"; then
  log_error "Failed to scale $WEB_DEPLOYMENT_NAME to 0 replicas. Exiting..."
  exit 1
fi

log_info "Delete jobs and monitoring resources..."
delete_resource_if_exists cronjob check-pod-logs
delete_resource_if_exists deployment pod-health-monitor
delete_resource_if_exists deployment $CRON_NAME
delete_resource_if_exists job moodle-upgrade
delete_resource_if_exists job migrate-build-files

# Delete ConfigMaps
delete_resource_if_exists configmap $CRON_NAME-config
delete_resource_if_exists configmap pod-health-monitor-script
delete_resource_if_exists configmap log-aggregator-script

# Create ConfigMaps for application components
create_or_update_configmap "$WEB_DEPLOYMENT_NAME-config" "default.conf=./config/nginx/fastcgi.conf"
create_or_update_configmap "$WEB_DEPLOYMENT_NAME-nginx-root-config" "./config/nginx/nginx.conf"
create_or_update_configmap "$APP-config" "config.php=./config/moodle/$DEPLOY_ENVIRONMENT.config.php"
create_or_update_configmap "$PHP_DEPLOYMENT_NAME-fpm-config" "zz-docker.conf=./config/php/php-fpm.conf"
create_or_update_configmap "$CRON_NAME-config" "config.php=./config/cron/$DEPLOY_ENVIRONMENT.config.php"
create_or_update_configmap "$CRON_NAME-php-config" "moodle-php.ini=./config/php/php.ini"
create_or_update_configmap "$CRON_NAME-shell" "cron.sh=./config/cron/cron.sh"

# Create ConfigMaps for monitoring scripts with modular utilities
create_or_update_configmap "check-pod-logs-script" \
  "check-pod-logs.sh=./openshift/scripts/check-pod-logs.sh" \
  "${UTILITY_CONFIGMAP_ARGS[@]}" \
  "galera-inspect.sh=./openshift/scripts/galera-inspect.sh" \
  "galera-recover.sh=./openshift/scripts/galera-recover.sh" \
  "content_replacement_columns.csv=./openshift/scripts/includes/content_replacement_columns.csv" \
  "find-courses-with-tag.php=./config/moodle/find-courses-with-tag.php"

create_or_update_configmap "pod-health-monitor-script" \
  "monitor-pods.sh=./openshift/scripts/monitor-pods.sh"

create_or_update_configmap "log-aggregator-script" \
  "log-aggregator.sh=./openshift/scripts/log-aggregator.sh"

create_or_update_configmap "migrate-courses" \
  "update-course-tag.php=./config/moodle/update-course-tag.php" \
  "find-courses-with-tag.php=./config/moodle/find-courses-with-tag.php"

# Annotate the web deployment to trigger a restart if it already exists
if [[ `oc describe deployment/$WEB_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  log_debug "$WEB_DEPLOYMENT_NAME NOT FOUND..."
else
  log_info "$WEB_DEPLOYMENT_NAME Installation FOUND...UPDATING..."
  oc annotate --overwrite  deployment/$WEB_DEPLOYMENT_NAME kubectl.kubernetes.io/restartedAt=`date +%FT%T`
fi

log_info "Deploy Template to OpenShift ..."
deploy_resource_from_template ./openshift/template.json \
  "APP_NAME=$APP" \
  "DB_HOST=$DB_HOST" \
  "DB_USER=$DB_USER" \
  "DB_NAME=$DB_NAME" \
  "DB_PASSWORD=$DB_PASSWORD" \
  "SITE_URL=$APP_HOST_URL" \
  "BUILD_NAMESPACE=$BUILD_NAMESPACE" \
  "DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE" \
  "IMAGE_REPO=$IMAGE_REPO" \
  "WEB_DEPLOYMENT_NAME=$WEB_DEPLOYMENT_NAME" \
  "WEB_IMAGE=$WEB_IMAGE" \
  "CRON_NAME=$CRON_NAME" \
  "PHP_DEPLOYMENT_NAME=$PHP_DEPLOYMENT_NAME" \
  "REDIS_HOST=$REDIS_HOST" \
  "REDIS_PORT=$REDIS_PORT" \
  "MOODLE_DEPLOYMENT_NAME=$MOODLE_DEPLOYMENT_NAME"

log_info "Create and run migrate-build-files job..."
deploy_resource_from_template ./openshift/migrate-build-files.yml \
    IMAGE_REPO=$IMAGE_REPO \
    BUILD_NAME=moodle \
    BUILD_NAMESPACE=$BUILD_NAMESPACE \
    FORCE_MIGRATE=$FORCE_MIGRATE \
    ARTIFACTORY_PULL_SECRET=$ARTIFACTORY_PULL_SECRET
if ! wait_for "job/migrate-build-files" "complete" "800s"; then
  log_error "Failed to run migrate-build-files job. Exiting..."
  exit 1
fi

while true; do
  # Ensure that the Redis proxy is deployed and error-free
  wait_for_deployment_without_errors "deployment/redis-proxy"

  log_info "Create and run Moodle upgrade job..."

  deploy_resource_from_template ./openshift/moodle-upgrade.yml \
    IMAGE_REPO=$IMAGE_REPO \
    DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
    BUILD_NAME=$PHP_DEPLOYMENT_NAME
  if ! wait_for "job/moodle-upgrade" "complete" "800s"; then
    log_error "Failed to run Moodle upgrade job. Exiting..."
    exit 1
  fi

  # Wait for "File copy complete" message
  # Get the name of the pod created by the job
  pod_name=$(oc get pods --selector=job-name=moodle-upgrade -o jsonpath='{.items[0].metadata.name}')
  error_detected=false
  oc logs -f $pod_name | while read line; do
    if [[ $line == *"Exception"* || $line == *"read error on connection to redis-proxy"* ]]; then
      log_error "Error detected during Moodle upgrade: $line"
      error_detected=true
      pkill -P $$ oc
    fi
    if [[ $line == *"Maintenance mode has been disabled and the site is running normally again"* ]]; then
      log_info "$line"
      pkill -P $$ oc
    fi
  done

  if $error_detected; then
    log_warn "Restarting Redis proxy and retrying Moodle upgrade..."
    wait_for_deployment_without_errors "deployment/redis-proxy"
    continue
  fi

  # If no errors were detected, break out of the loop
  break
done

# Scale [up] php to 1 replica
scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "1" "1"
if ! wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "600s"; then
  log_error "Failed to scale $PHP_DEPLOYMENT_NAME to 1 replica. Exiting..."
  exit 1
fi

sleep 10

# Right-sizing cluster, according to environment
bash ./openshift/scripts/right-sizing.sh

sleep 60

# Clear Moodle cache across all PHP pods after successful deployment
log_info "🧹 Clearing Moodle cache across PHP deployment..."

# Debug: Check if the function exists before calling it
log_debug "Debugging function availability..."
if declare -f clear_moodle_cache_deployment > /dev/null 2>&1; then
  log_debug "Function clear_moodle_cache_deployment is available"
else
  log_error "Function clear_moodle_cache_deployment is NOT available"
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    log_debug "📋 Available cache-related functions:"
    declare -F | grep -i cache || log_debug "   No cache functions found"
    log_debug "📋 All available functions from _utils.sh:"
    declare -F | grep -E "(moodle|cache|clear)" || log_debug "   No matching functions found"
  fi
fi

# Syntax check of utility files
if ! validate_utility_files; then
  log_error "Utility file validation failed. Exiting..."
  exit 1
fi

clear_moodle_cache_deployment "$PHP_DEPLOYMENT_NAME" "$DEPLOY_NAMESPACE" "bcgovpsa"

# Update Redis proxy configuration after right-sizing (Phase 2)
log_info "🔧 Updating Redis proxy configuration after right-sizing..."
update_redis_proxy_after_scaling "$REDIS_NAME" "$REDIS_PROXY_NAME" "$DEPLOY_NAMESPACE"

# =============================================================================
# DATABASE READINESS GATE
# Verify MariaDB/Galera cluster is healthy BEFORE restoring routes.
# Specifically checks for split-brain (multiple cluster UUIDs), which causes
# "Error reading from database" when pods serve from divergent data sets.
# =============================================================================
log_info "🔍 Verifying Galera cluster health before restoring user-facing routes..."
check_galera_cluster_health "app.kubernetes.io/name=$DB_DEPLOYMENT_NAME" "$DEPLOY_NAMESPACE"
GALERA_HEALTH=$?
if [[ $GALERA_HEALTH -eq 2 ]]; then
  log_error "🚨 SPLIT-BRAIN DETECTED — aborting route restoration to protect users"
  log_error "Site remains in maintenance mode. Manual intervention required:"
  log_error "  1. Identify the primary node (highest seqno in grastate.dat)"
  log_error "  2. Scale galera to 1 replica (keep primary only)"
  log_error "  3. Delete PVCs for secondary nodes"
  log_error "  4. Scale back up — secondaries will SST from primary"
  exit 1
elif [[ $GALERA_HEALTH -eq 1 ]]; then
  log_error "Database cluster is unhealthy — aborting route restoration to protect users"
  log_error "Site remains in maintenance mode. Investigate MariaDB/Galera health:"
  log_error "  oc get pods -l app.kubernetes.io/name=$DB_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE"
  log_error "  oc exec <galera-pod> -- mariadb -u\$DB_USER -p\$DB_PASSWORD -e \"SHOW STATUS LIKE 'wsrep%';\""
  exit 1
fi

# Disable maintenance mode with integrated verification and scaling
log_info "🔄 Disabling maintenance mode with automatic verification and cleanup..."
manage_maintenance_mode "disable" "web" "auto"

log_success "Deployment complete."
