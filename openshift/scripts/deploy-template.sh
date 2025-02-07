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

# Redirect traffic to maintenance-message
echo "Redirecting traffic to maintenance-message..."
patch_route moodle-web maintenance-message

# Scale php to 1 replica
oc scale deployment/$PHP_DEPLOYMENT_NAME --replicas=1
wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "120s"

# Define HPA settings
HPAS=(
  "php deployment/$PHP_DEPLOYMENT_NAME 3 20 200m"
  "redis-node sts/redis-node 6 20 80m"
  "redis-proxy deployment/redis-proxy 3 20 3m"
  "web deployment/$WEB_DEPLOYMENT_NAME 3 20 4m"
)

# Delete existing HPAs
for HPA in "${HPAS[@]}"; do
  NAME=$(echo $HPA | awk '{print $1}')
  echo "Deleting existing HPA: $NAME"
  oc delete hpa $NAME --ignore-not-found
done

# Ensure secrets are linked for pulling from Artifactory
oc secrets link default artifactory-m950-learning --for=pull

# Enable Moodle maintenance mode
# Should probbaly call cron deployment for this
manage_maintenance_mode "enable" $PHP_DEPLOYMENT_NAME

# Scale web to 0 replicas
oc scale deployment/$WEB_DEPLOYMENT_NAME --replicas=0
wait_for "deployment/$WEB_DEPLOYMENT_NAME" "ready" "60s" "down"

echo "Delete cron job if it exists..."
# Check if cron exists
if oc get deployment $CRON_NAME; then
  echo "$CRON_NAME Installation FOUND...Deleting..."
  oc delete deployment $CRON_NAME
fi

# Create ConfigMaps (first delete, if necessary)
if [[ ! `oc describe configmap $WEB_DEPLOYMENT_NAME-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $WEB_DEPLOYMENT_NAME-config"
  oc delete configmap $WEB_DEPLOYMENT_NAME-config
fi

echo "Creating configMap: $WEB_DEPLOYMENT_NAME-config"
oc create configmap $WEB_DEPLOYMENT_NAME-config --from-file=./config/nginx/default.conf

if [[ ! `oc describe configmap $APP-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $APP-config"
  oc delete configmap $APP-config
fi

echo "Creating configMap: $APP-config"
oc create configmap $APP-config --from-file=config.php=./config/moodle/$DEPLOY_ENVIRONMENT.config.php

if [[ ! `oc describe configmap $CRON_NAME-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $CRON_NAME-config"
  oc delete configmap $CRON_NAME-config
fi

if [[ ! `oc describe configmap $PHP_DEPLOYMENT_NAME-fpm-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $PHP_DEPLOYMENT_NAME-fpm-config"
  oc delete configmap $PHP_DEPLOYMENT_NAME-fpm-config
fi

echo "Creating configMap: $PHP_DEPLOYMENT_NAME-fpm-config"
oc create configmap $PHP_DEPLOYMENT_NAME-fpm-config --from-file=zz-docker.conf=./config/php/php-fpm.conf

echo "Creating configMap: $CRON_NAME-config"
oc create configmap $CRON_NAME-config --from-file=config.php=./config/cron/$DEPLOY_ENVIRONMENT.config.php

echo "Creating configMap: check-pod-logs-script"
if [[ ! `oc describe configmap check-pod-logs-script 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: check-pod-logs-script"
  oc delete configmap check-pod-logs-script
fi
oc create configmap check-pod-logs-script --from-file=check-pod-logs.sh=./openshift/scripts/check-pod-logs.sh
oc process -f ./openshift/cron-check-errors-template.yml \
  -p OPENSHIFT_SERVER=$OPENSHIFT_SERVER \
  | oc apply -f -

echo "Checking for: deployment/$WEB_DEPLOYMENT_NAME in $DEPLOY_NAMESPACE"

if [[ `oc describe deployment/$WEB_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$WEB_DEPLOYMENT_NAME NOT FOUND..."
else
  echo "$WEB_DEPLOYMENT_NAME Installation FOUND...UPDATING..."
  oc annotate --overwrite  deployment/$WEB_DEPLOYMENT_NAME kubectl.kubernetes.io/restartedAt=`date +%FT%T`
fi

# Only use 1 redis replica for deployment / upgrade to avoid conflicts
echo "Scale down $PHP_DEPLOYMENT_NAME to 0 replicas..."
oc scale deployment/$PHP_DEPLOYMENT_NAME --replicas=0
wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "60s" "down"

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

echo "Rolling out $PHP_DEPLOYMENT_NAME..."
wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "360s"

# Check if the moodle-upgrade exists, if so, delete it
if [[ `oc describe job moodle-upgrade 2>&1` =~ "NotFound" ]]; then
  echo "moodle-upgrade job NOT FOUND..."
else
  echo "moodle-upgrade job found... deleting..."
  oc delete job moodle-upgrade
fi

# Check if the migrate-build-files job exists, if so, delete it
if [[ `oc describe job migrate-build-files 2>&1` =~ "NotFound" ]]; then
  echo "migrate-build-files job NOT FOUND..."
else
  echo "migrate-build-files job FOUND...Deleting..."
  oc delete job/migrate-build-files
fi

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

echo "Scaling up php to 3 replicas..."
oc scale deployment/$PHP_DEPLOYMENT_NAME --replicas=3
wait_for "deployment/$PHP_DEPLOYMENT_NAME" "ready" "360s"

echo "Purging caches..."
oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/purge_caches.php' --wait

echo "Purging missing plugins..."
plugin_purge=$(oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run' --wait)
echo "Result: $plugin_purge"

# Scale web to 3 replicas
oc scale deployment/$WEB_DEPLOYMENT_NAME --replicas=3
wait_for "deployment/$WEB_DEPLOYMENT_NAME" "ready" "120s"

# Right-sizing cluster, according to environment
# bash ./openshift/scripts/right-sizing.sh

# Create new HPAs
for HPA in "${HPAS[@]}"; do
  NAME=$(echo $HPA | awk '{print $1}')
  TARGET=$(echo $HPA | awk '{print $2}')
  MIN_REPLICAS=$(echo $HPA | awk '{print $3}')
  MAX_REPLICAS=$(echo $HPA | awk '{print $4}')
  AVG_VALUE=$(echo $HPA | awk '{print $5}')

  echo "Creating HPA: $NAME"

  # Determine the kind of the target resource
  KIND="Deployment"
  if [[ $TARGET == sts/* ]]; then
    KIND="StatefulSet"
    TARGET=${TARGET#sts/}
  elif [[ $TARGET == deployment/* ]]; then
    TARGET=${TARGET#deployment/}
  fi

  # Create a temporary template file
  cat <<EOF > hpa.yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: $NAME
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: $KIND
    name: $TARGET
  minReplicas: $MIN_REPLICAS
  maxReplicas: $MAX_REPLICAS
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageValue: $AVG_VALUE
EOF

  echo "Creating HPA from template:"
  echo $(cat hpa.yaml)
  oc create -f hpa.yaml

  wait_for_deployment_without_errors "$TARGET"
  wait_for "deployment/$WEB_DEPLOYMENT_NAME" "ready" "120s"
done

# Disable maintenance mode and verify output
echo "Disabling maintenance mode..."
manage_maintenance_mode "disable" $PHP_DEPLOYMENT_NAME

# Create / update web route to direct traffic [back] to app
oc process -f ./openshift/web-route.yml \
  -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  -p APP_NAME=$APP \
  -p WEB_DEPLOYMENT_NAME=$WEB_DEPLOYMENT_NAME \
  -p SITE_URL=$SITE_URL \
  | oc create -f -

echo "Redirecting traffic [back] to Moodle..."
patch_route $APP-$WEB_DEPLOYMENT_NAME $WEB_DEPLOYMENT_NAME

oc scale deployment/maintenance-message --replicas=0

echo "Deployment complete."

# Wait for things to warm up a bit before proceeding with the [lighthouse] tests
sleep 30
