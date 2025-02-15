#!/bin/bash
#set -e # Exit on error

# Source the utility script
source ./openshift/scripts/_utils.sh

test -n $DEPLOY_NAMESPACE
oc project $DEPLOY_NAMESPACE
echo "Current namespace is $DEPLOY_NAMESPACE"

# Scale maintenance-message to 1 replica
oc scale deployment/maintenance-message --replicas=1
wait_for "deployment/maintenance-message"

# Create / update web route
envsubst < ./openshift/web-route.yml | oc apply -f -
# Apply timeout to route
# oc annotate route $APP-$WEB_DEPLOYMENT_NAME --overwrite haproxy.router.openshift.io/timeout=180s

# Redirect traffic to maintenance-message
echo "Redirecting traffic to maintenance-message..."
patch_route $APP-$WEB_DEPLOYMENT_NAME maintenance-message

# Enable Moodle maintenance mode
# Should probbaly call cron deployment for this
manage_maintenance_mode "enable" $PHP_DEPLOYMENT_NAME

# Ensure secrets are linked for pulling from Artifactory
oc secrets link default artifactory-m950-learning --for=pull

# Scale [down] php to 0 replicas
scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "0" "0"
wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "120s" "down"

# Scale web to 0 replicas
scale_deployment "deployment" "$WEB_DEPLOYMENT_NAME" "0" "0"
wait_for "deployment/$WEB_DEPLOYMENT_NAME" "ready" "60s" "down"

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
create_or_update_configmap "check-pod-logs-script" "check-pod-logs.sh=./openshift/scripts/check-pod-logs.sh" "_utils.sh=./openshift/scripts/_utils.sh"

# Create cronjob to check pod logs for errors, and restart if necessary
oc process -f ./openshift/cron-check-errors-template.yml \
  -p OPENSHIFT_SERVER=$OPENSHIFT_SERVER \
  | oc apply -f -

# Annotate the web deployment to trigger a restart if it already exists
if [[ `oc describe deployment/$WEB_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$WEB_DEPLOYMENT_NAME NOT FOUND..."
else
  echo "$WEB_DEPLOYMENT_NAME Installation FOUND...UPDATING..."
  oc annotate --overwrite  deployment/$WEB_DEPLOYMENT_NAME kubectl.kubernetes.io/restartedAt=`date +%FT%T`
fi

echo "Deploy Template to OpenShift ..."
oc process -f ./openshift/template.json \
  -p APP_NAME=$APP \
  -p DB_HOST=$DB_HOST \
  -p DB_USER=$DB_USER \
  -p DB_NAME=$DB_NAME \
  -p DB_PASSWORD=$DB_PASSWORD \
  -p SITE_URL=$APP_HOST_URL \
  -p BUILD_NAMESPACE=$BUILD_NAMESPACE \
  -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  -p IMAGE_REPO=$IMAGE_REPO \
  -p WEB_DEPLOYMENT_NAME=$WEB_DEPLOYMENT_NAME \
  -p WEB_IMAGE=$WEB_IMAGE \
  -p CRON_NAME=$CRON_NAME \
  -p PHP_DEPLOYMENT_NAME=$PHP_DEPLOYMENT_NAME \
  -p REDIS_HOST=$REDIS_HOST \
  -p REDIS_PORT=$REDIS_PORT \
  -p MOODLE_DEPLOYMENT_NAME=$MOODLE_DEPLOYMENT_NAME | \
oc apply -f -

scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "1" "1"
wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "360s"

echo "Create and run migrate-build-files job..."
oc process -f ./openshift/migrate-build-files.yml | oc create -f -
wait_for "job/migrate-build-files" "complete" "800s"

echo "Create and run Moodle upgrade job..."
oc process -f ./openshift/moodle-upgrade.yml \
  -p IMAGE_REPO=$IMAGE_REPO \
  -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  -p BUILD_NAME=$PHP_DEPLOYMENT_NAME \
  | oc create -f -
wait_for "job/moodle-upgrade" "complete" "800s"

# Wait for the "File copy complete." message
# Get the name of the pod created by the job
pod_name=$(oc get pods --selector=job-name=moodle-upgrade -o jsonpath='{.items[0].metadata.name}')
oc logs -f $pod_name | while read line
do
  echo $line
  if [[ $line == *"Maintenance mode has been disabled and the site is running normally again"* ]]; then
    pkill -P $$ oc
  fi
done

echo "Purging caches..."
oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/purge_caches.php' --wait

echo "Purging missing plugins..."
plugin_purge=$(oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run' --wait)
echo "Result: $plugin_purge"

# Right-sizing cluster, according to environment
bash ./openshift/scripts/right-sizing.sh

# Ensure that the Redis proxy is deployed and error-free
wait_for_deployment_without_errors "deployment/redis-proxy"

# Disable maintenance mode and verify output
echo "Disabling maintenance mode..."
manage_maintenance_mode "disable" $PHP_DEPLOYMENT_NAME

echo "Directing traffic / route to Moodle..."
patch_route $APP-$WEB_DEPLOYMENT_NAME $WEB_DEPLOYMENT_NAME

oc scale deployment/maintenance-message --replicas=0

echo "Deployment complete."

# Wait for things to warm up a bit before proceeding with the [lighthouse] tests
sleep 30
