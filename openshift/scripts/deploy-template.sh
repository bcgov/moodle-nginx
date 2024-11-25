#!/bin/bash
#set -e # Exit on error

test -n $DEPLOY_NAMESPACE
oc project $DEPLOY_NAMESPACE
echo "Current namespace is $DEPLOY_NAMESPACE"

# Ensure secrets are linked for pulling from Artifactory
oc secrets link default artifactory-m950-learning --for=pull

# Enable Moodle maintenance mode
sh ./openshift/scripts/enable-maintenance.sh

sleep 10

# Redirect traffic to maintenance-message
echo "Redirecting traffic to maintenance-message..."
oc patch route moodle-web --type=json -p '[{"op": "replace", "path": "/spec/to/name", "value": "maintenance-message"}]'

sleep 60

echo "Delete cron job if it exists..."
# Check if cron exists
if oc get deployment $CRON_NAME; then
  echo "$CRON_NAME Installation FOUND...Deleting..."
  oc delete deployment $CRON_NAME
fi

# Only use 1 db replica for deployment / upgrade to avoid conflicts
echo "Scale down $DB_DEPLOYMENT_NAME to 1 replica..."
oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1

# Only use 1 redis replica for deployment / upgrade to avoid conflicts
echo "Scale down $REDIS_NAME to 1 replica..."
oc scale sts/$REDIS_NAME --replicas=1

# Create ConfigMaps (first delete, if necessary)
if [[ ! `oc describe configmap $WEB_DEPLOYMENT_NAME-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $WEB_DEPLOYMENT_NAME-config"
  oc delete configmap $WEB_DEPLOYMENT_NAME-config
fi

sleep 10

echo "Creating configMap: $WEB_DEPLOYMENT_NAME-config"
oc create configmap $WEB_DEPLOYMENT_NAME-config --from-file=./config/nginx/default.conf

if [[ ! `oc describe configmap $APP-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $APP-config"
  oc delete configmap $APP-config
fi

sleep 10

echo "Creating configMap: $APP-config"
oc create configmap $APP-config --from-file=config.php=./config/moodle/$DEPLOY_ENVIRONMENT.config.php

if [[ ! `oc describe configmap $CRON_NAME-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $CRON_NAME-config"
  oc delete configmap $CRON_NAME-config
fi

sleep 10

echo "Creating configMap: $CRON_NAME-config"
oc create configmap $CRON_NAME-config --from-file=config.php=./config/cron/$DEPLOY_ENVIRONMENT.config.php

sleep 10

echo "Checking for: deployment/$WEB_DEPLOYMENT_NAME in $DEPLOY_NAMESPACE"

if [[ `oc describe deployment/$WEB_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$WEB_DEPLOYMENT_NAME NOT FOUND..."
else
  echo "$WEB_DEPLOYMENT_NAME Installation FOUND...UPDATING..."
  oc annotate --overwrite  deployment/$WEB_DEPLOYMENT_NAME kubectl.kubernetes.io/restartedAt=`date +%FT%T`
  oc rollout latest deployment/$WEB_DEPLOYMENT_NAME
fi

sleep 30

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

# Only use 1 db replica for deployment / upgrade to avoid conflicts
echo "Scale down $DB_DEPLOYMENT_NAME to 1 replica..."
oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1

# Redirect traffic to maintenance-message
echo "Redirecting traffic to maintenance-message..."
oc patch route moodle-web --type=json -p '[{"op": "replace", "path": "/spec/to/name", "value": "maintenance-message"}]'

sleep 60

echo "Rolling out $PHP_DEPLOYMENT_NAME..."
oc rollout latest deployment/$PHP_DEPLOYMENT_NAME

# Check PHP deployment rollout status until complete.
ATTEMPTS=0
WAIT_TIME=30
ROLLOUT_STATUS_CMD="oc rollout status deployment/$PHP_DEPLOYMENT_NAME"
until $ROLLOUT_STATUS_CMD || [ $ATTEMPTS -eq 6 ]; do
  $ROLLOUT_STATUS_CMD
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ $ATTEMPTS -eq 10 ]; then
    echo "Deployment/$PHP_DEPLOYMENT_NAME rollout failed. Exiting..."
    exit 1
  fi
  echo "Waiting for deployment/$PHP_DEPLOYMENT_NAME: $(($ATTEMPTS * $WAIT_TIME)) seconds..."
  sleep $WAIT_TIME
done

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

sleep 10

echo "Create and run migrate-build-files job..."
oc process -f ./openshift/migrate-build-files.yml | oc create -f -

sleep 10

# Get the name of the pod created by the job
pod_name=$(oc get pods --selector=job-name=migrate-build-files -o jsonpath='{.items[0].metadata.name}')

# Wait until the pod is in the "Running" state
while [[ $(oc get pod $pod_name -o 'jsonpath={..status.phase}') != "Running" ]]; do
  echo "Waiting for pod $pod_name to be running."
  sleep 30
done

# Wait for the migrate-build-files job to complete
echo "Pod $pod_name is now running."

echo "Waiting for $pod_name job to complete..."

sleep 60

COUNT=0
SLEEP=10
while true; do
  # Make sure we have the most current name of the pod created by the job
  job_status=$(oc get jobs migrate-build-files -o 'jsonpath={..status.failed}')
  pod_name=$(oc get pods --selector=job-name=migrate-build-files -o jsonpath='{.items[0].metadata.name}')
  message=$(oc logs $pod_name)
  if [[ $job_status > 0 ]]; then
    echo "migrate-build-files job has failed... Exiting due to error: $message"
    exit 1
  fi
  if [[ $(oc get jobs migrate-build-files -o 'jsonpath={..status.active}') != "1" ]]; then
    break
  fi
  echo "migrate-build-files job is still running... $(($COUNT * $SLEEP + 60)) seconds..."
  COUNT=$((COUNT + 1))
  sleep $SLEEP
done
echo "migrate-build-files job has completed."

sleep 15

echo "Create and run Moodle upgrade job..."
oc process -f ./openshift/moodle-upgrade.yml \
  -p IMAGE_REPO=$IMAGE_REPO \
  -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  -p BUILD_NAME=$PHP_DEPLOYMENT_NAME \
  | oc create -f -

sleep 15

# Get the name of the pod created by the job
pod_name=$(oc get pods --selector=job-name=moodle-upgrade -o jsonpath='{.items[0].metadata.name}')

# Wait until the pod is in the "Running" state
while [[ $(oc get pod $pod_name -o 'jsonpath={..status.phase}') != "Running" ]]; do
  echo "Waiting for pod $pod_name to be running."
  sleep 10
done

sleep 30

echo "Waiting for moodle-upgrade job to complete..."
COUNT=0
while [[ $(oc get jobs moodle-upgrade -o 'jsonpath={..status.active}') == "1" ]]; do
  echo "moodle-upgrade job is still running..."
  COUNT=$((COUNT + 1))
  sleep $SLEEP
done
echo "moodle-upgrade job has completed."

# Wait for the "File copy complete." message
oc logs -f $pod_name | while read line
do
  echo $line
  if [[ $line == *"Maintenance mode has been disabled and the site is running normally again"* ]]; then
    pkill -P $$ oc
  fi
done

echo "Purging caches..."
oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/purge_caches.php'

sleep 10

echo "Purging missing plugins..."
plugin_purge=$(oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run')
echo "Result: $plugin_purge"

sleep 10

echo "Running Moodle upgrades..."
moodle_upgrade_result=$(oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/upgrade.php --non-interactive')
echo "Result: $moodle_upgrade_result"

sleep 10

# DB was scaled-down for deployment and maintenance, scale it back up
echo "Scaling up $DB_DEPLOYMENT_NAME to 3 replicas..."
oc scale sts/$DB_DEPLOYMENT_NAME --replicas=3

# Right-sizing cluster, according to environment
bash ./openshift/scripts/right-sizing.sh

sleep 10

echo "Disabling maintenance mode..."
oc exec deployment/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/maintenance.php --disable'

echo "Disabling maintenance-message and redirecting traffic [back] to Moodle..."
oc patch route moodle-web --type=json -p '[{"op": "replace", "path": "/spec/to/name", "value": "web"}]'

sleep 30

oc scale deployment/maintenance-message --replicas=0

echo "Deployment complete."

# Wait for things to warm up a bit before proceeding with the [lighthouse] tests
sleep 120
