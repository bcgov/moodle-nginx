#!/bin/bash
#set -e # Exit on error

# Source the utility script
source ./openshift/scripts/_utils.sh

test -n $DEPLOY_NAMESPACE
oc project $DEPLOY_NAMESPACE
echo "Current namespace is $DEPLOY_NAMESPACE"

# Enable Moodle maintenance mode
manage_maintenance_mode "enable" "maintenance-message"

# Ensure secrets are linked for pulling from Artifactory
oc secrets link default artifactory-m950-learning --for=pull

# Scale [down] php to 0 replicas
scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "0" "0"
if ! wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "120s" "down"; then
  echo "Failed to scale $PHP_DEPLOYMENT_NAME to 0 replicas. Exiting..."
  exit 1
fi

# Scale [down] web to 0 replicas
scale_deployment "deployment" "$WEB_DEPLOYMENT_NAME" "0" "0"
if ! wait_for "deployment/$WEB_DEPLOYMENT_NAME" "ready" "600s" "down"; then
  echo "Failed to scale $WEB_DEPLOYMENT_NAME to 0 replicas. Exiting..."
  exit 1
fi

echo "Delete jobs..."
delete_resource_if_exists cronjob check-pod-logs
delete_resource_if_exists deployment $CRON_NAME
delete_resource_if_exists job moodle-upgrade
delete_resource_if_exists job migrate-build-files

# Delete ConfigMaps
delete_resource_if_exists configmap $CRON_NAME-config

# Create ConfigMaps
create_or_update_configmap "$WEB_DEPLOYMENT_NAME-config" "default.conf=./config/nginx/fastcgi.conf"
create_or_update_configmap "$WEB_DEPLOYMENT_NAME-nginx-root-config" "./config/nginx/nginx.conf"
create_or_update_configmap "$APP-config" "config.php=./config/moodle/$DEPLOY_ENVIRONMENT.config.php"
create_or_update_configmap "$PHP_DEPLOYMENT_NAME-fpm-config" "zz-docker.conf=./config/php/php-fpm.conf"
create_or_update_configmap "$CRON_NAME-config" "config.php=./config/cron/$DEPLOY_ENVIRONMENT.config.php"
create_or_update_configmap "$CRON_NAME-php-config" "moodle-php.ini=./config/php/php.ini"
create_or_update_configmap "$CRON_NAME-shell" "cron.sh=./config/cron/cron.sh"
create_or_update_configmap "check-pod-logs-script" "check-pod-logs.sh=./openshift/scripts/check-pod-logs.sh" "_utils.sh=./openshift/scripts/_utils.sh" "content_replacement_columns.csv=./openshift/scripts/includes/content_replacement_columns.csv"
create_or_update_configmap "migrate-courses" "update-course-tag.php=./config/moodle/update-course-tag.php" "find-courses-with-tag.php=./config/moodle/find-courses-with-tag.php"

# Annotate the web deployment to trigger a restart if it already exists
if [[ `oc describe deployment/$WEB_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$WEB_DEPLOYMENT_NAME NOT FOUND..."
else
  echo "$WEB_DEPLOYMENT_NAME Installation FOUND...UPDATING..."
  oc annotate --overwrite  deployment/$WEB_DEPLOYMENT_NAME kubectl.kubernetes.io/restartedAt=`date +%FT%T`
fi

echo "Deploy Template to OpenShift ..."
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

echo "Create and run migrate-build-files job..."
deploy_resource_from_template ./openshift/migrate-build-files.yml \
    IMAGE_REPO=$IMAGE_REPO \
    BUILD_NAME=moodle \
    BUILD_NAMESPACE=$BUILD_NAMESPACE \
    FORCE_MIGRATE=$FORCE_MIGRATE
if ! wait_for "job/migrate-build-files" "complete" "800s"; then
  echo "Failed to run migrate-build-files job. Exiting..."
  exit 1
fi

while true; do
  # Ensure that the Redis proxy is deployed and error-free
  wait_for_deployment_without_errors "deployment/redis-proxy"

  echo "Create and run Moodle upgrade job..."
  deploy_resource_from_template ./openshift/moodle-upgrade.yml \
    IMAGE_REPO=$IMAGE_REPO \
    DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
    BUILD_NAME=$PHP_DEPLOYMENT_NAME
  if ! wait_for "job/moodle-upgrade" "complete" "800s"; then
    echo "Failed to run Moodle upgrade job. Exiting..."
    exit 1
  fi

  # Wait for "File copy complete" message
  # Get the name of the pod created by the job
  pod_name=$(oc get pods --selector=job-name=moodle-upgrade -o jsonpath='{.items[0].metadata.name}')
  error_detected=false
  oc logs -f $pod_name | while read line; do
    if [[ $line == *"Exception"* || $line == *"read error on connection to redis-proxy"* ]]; then
      echo "Error detected during Moodle upgrade: $line"
      error_detected=true
      pkill -P $$ oc
    fi
    if [[ $line == *"Maintenance mode has been disabled and the site is running normally again"* ]]; then
      echo $line
      pkill -P $$ oc
    fi
  done

  if $error_detected; then
    echo "Restarting Redis proxy and retrying Moodle upgrade..."
    wait_for_deployment_without_errors "deployment/redis-proxy"
    continue
  fi

  # If no errors were detected, break out of the loop
  break
done

# Scale [up] php to 1 replica
scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "1" "1"
if ! wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "600s"; then
  echo "Failed to scale $PHP_DEPLOYMENT_NAME to 1 replica. Exiting..."
  exit 1
fi

sleep 10

# Right-sizing cluster, according to environment
bash ./openshift/scripts/right-sizing.sh

# Create cronjob to check pod logs for errors, and restart if necessary
deploy_resource_from_template ./openshift/check-pod-logs.yml \
  OPENSHIFT_SERVER=$OPENSHIFT_SERVER \
  OPENSHIFT_SA_TOKEN_NAME=$OPENSHIFT_SA_TOKEN_NAME \
  DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE

sleep 60

# Clear Moodle cache across all PHP pods after successful deployment
echo "🧹 Clearing Moodle cache across PHP deployment..."

# Debug: Check if the function exists before calling it
echo "🔍 Debugging function availability..."
if declare -f clear_moodle_cache_deployment > /dev/null 2>&1; then
  echo "✅ Function clear_moodle_cache_deployment is available"
else
  echo "❌ Function clear_moodle_cache_deployment is NOT available"
  echo "📋 Available cache-related functions:"
  declare -F | grep -i cache || echo "   No cache functions found"
  echo "📋 All available functions from _utils.sh:"
  declare -F | grep -E "(moodle|cache|clear)" || echo "   No matching functions found"
fi

# Syntax check of _utils.sh
echo "🔍 Validating _utils.sh syntax..."
if bash -n ./openshift/scripts/_utils.sh; then
  echo "✅ _utils.sh syntax is valid"
else
  echo "❌ _utils.sh has syntax errors"
  exit 1
fi

clear_moodle_cache_deployment "$PHP_DEPLOYMENT_NAME" "$DEPLOY_NAMESPACE" "bcgovpsa"

# Update Redis proxy configuration after right-sizing (Phase 2)
echo "🔧 Updating Redis proxy configuration after right-sizing..."
update_redis_proxy_after_scaling "$REDIS_NAME" "$REDIS_PROXY_NAME" "$DEPLOY_NAMESPACE"

# Disable maintenance mode with integrated verification and scaling
echo "🔄 Disabling maintenance mode with automatic verification and cleanup..."
manage_maintenance_mode "disable" "web" "auto"

echo "Deployment complete."
