test -n "$DEPLOY_NAMESPACE"
oc project $DEPLOY_NAMESPACE
echo "Current namespace is $DEPLOY_NAMESPACE"

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
oc create configmap $APP-config --from-file=config.php=./config/moodle/$MOODLE_ENVIRONMENT.config.php

if [[ ! `oc describe configmap $CRON_DEPLOYMENT_NAME-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $CRON_DEPLOYMENT_NAME-config"
  oc delete configmap $CRON_DEPLOYMENT_NAME-config
fi
echo "Creating configMap: $CRON_DEPLOYMENT_NAME-config"
oc create configmap $CRON_DEPLOYMENT_NAME-config --from-file=config.php=./config/cron/$MOODLE_ENVIRONMENT.config.php

echo "Building php to: $IMAGE_REPO/$PHP_DEPLOYMENT_NAME:$DEPLOY_NAMESPACE"

if [[ `oc describe dc $WEB_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$WEB_DEPLOYMENT_NAME NOT FOUND..."
else
  echo "$WEB_DEPLOYMENT_NAME Installation FOUND...UPDATING..."
  oc annotate --overwrite  dc/$WEB_DEPLOYMENT_NAME kubectl.kubernetes.io/restartedAt=`date +%FT%T`
  oc rollout latest dc/$WEB_DEPLOYMENT_NAME
fi

oc process -f ./openshift/template.json \
  -p APP_NAME=$APP \
  -p DB_USER=$DB_USER \
  -p DB_NAME=$DB_NAME \
  -p DB_PASSWORD=$DB_PASSWORD \
  -p BUILD_TAG=$BUILD_TAG \
  -p SITE_URL=$APP_HOST_URL \
  -p BUILD_NAMESPACE=$BUILD_NAMESPACE \
  -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  -p IMAGE_REPO=$IMAGE_REPO \
  -p WEB_DEPLOYMENT_NAME=$WEB_DEPLOYMENT_NAME \
  -p WEB_IMAGE=$WEB_IMAGE \
  -p CRON_IMAGE=$CRON_IMAGE \
  -p CRON_DEPLOYMENT_NAME=$CRON_DEPLOYMENT_NAME \
  -p PHP_DEPLOYMENT_NAME=$PHP_DEPLOYMENT_NAME \
  -p MOODLE_DEPLOYMENT_NAME=$MOODLE_DEPLOYMENT_NAME | \
oc apply -f -

# echo "Rolling out $MOODLE_DEPLOYMENT_NAME..."
# oc rollout latest dc/$MOODLE_DEPLOYMENT_NAME

echo "Rolling out $PHP_DEPLOYMENT_NAME..."
oc rollout latest dc/$PHP_DEPLOYMENT_NAME

# echo "Rolling out $CRON_DEPLOYMENT_NAME..."
# oc rollout latest dc/$CRON_DEPLOYMENT_NAME

# Check PHP deployment rollout status until complete.
ATTEMPTS=0
WAIT_TIME=5
ROLLOUT_STATUS_CMD="oc rollout status dc/$PHP_DEPLOYMENT_NAME"
until $ROLLOUT_STATUS_CMD || [ $ATTEMPTS -eq 120 ]; do
  $ROLLOUT_STATUS_CMD
  ATTEMPTS=$((attempts + 1))
  echo "Waiting for dc/$PHP_DEPLOYMENT_NAME: $(($ATTEMPTS * $WAIT_TIME)) seconds..."
  sleep $WAIT_TIME
done

# Check Moodle deployment rollout status until complete.
# ATTEMPTS=0
# WAIT_TIME=5
# ROLLOUT_STATUS_CMD="oc rollout status dc/$MOODLE_DEPLOYMENT_NAME"
# until $ROLLOUT_STATUS_CMD || [ $ATTEMPTS -eq 120 ]; do
#   $ROLLOUT_STATUS_CMD
#   ATTEMPTS=$((attempts + 1))
#   echo "Waited: $(($ATTEMPTS * $WAIT_TIME)) seconds..."
#   sleep $WAIT_TIME
# done

# Enable Maintenance mode (PHP)
echo "Enabling Moodle maintenance mode..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/maintenance.php --enable' --wait

echo "Create and run Moodle build migration job..."
oc process -f ./openshift/migrate-build-files-job.yml | oc create -f -

echo "Waiting for Moodle build migration job status to complete..."
ATTEMPTS=0
WAIT_TIME=5
#  2>&1` =~ "NotFound"
# oc get jobs | findstr /i 'migrate-build-files 1/1'
MIGRATE_STATUS_CMD='oc get jobs 2>&1` =~ "migrate-build-files"'
until $MIGRATE_STATUS_CMD || [ $ATTEMPTS -eq 120 ]; do
  $MIGRATE_STATUS_CMD
  ATTEMPTS=$(( $ATTEMPTS + 1 ))
  echo "Waited: $(($ATTEMPTS * $WAIT_TIME)) seconds..."
  sleep $WAIT_TIME
done

# Check if the moodle-upgrade-job exists
if oc get job moodle-upgrade-job; then
  # If the job exists, delete it
  oc delete job moodle-upgrade-job
fi

echo "Create and run Moodle upgrade job..."
oc process -f ./openshift/moodle-upgrade-job.yml | oc create -f -

# # Ensure moodle config is cleared (Moodle)
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c 'rm -f /var/www/html/config.php'

# MOODLE_APP_DIR=/var/www/html

# # Delete existing plugins (PHP)
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/admin/tool/trigger"
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/admin/tool/dataflows"
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/facetoface"
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/hvp"
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/course/format/topcoll"
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/customcert"
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/certificate"

# # Copy / update all files from docker build to shared PVC (Moodle)
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c 'cp -ru /app/public/* /var/www/html'

echo "Purging caches..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/purge_caches.php'

echo "Purging missing plugins..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run'

echo "Running Moodle upgrades..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/upgrade.php --non-interactive'

echo "Disabling maintenance mode..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/maintenance.php --disable'


echo "Create and run Moodle cron job..."
oc process -f ./openshift/moodle-cron-job.yml | oc create -f -

# echo "Run first cron..."
# oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/cron.php'

# echo "Listing pods..."
# oc get pods|grep $PHP_DEPLOYMENT_NAME
# sleep 30
# oc get pods -l deploymentconfig=$PHP_DEPLOYMENT_NAME --field-selector=status.phase=Running -o name
# sleep 20
# podNames=$(oc get pods -l deploymentconfig=$PHP_DEPLOYMENT_NAME --field-selector=status.phase=Running -o name)
# pwd
# echo "$PHP_DEPLOYMENT_NAME is deployed"
# echo "deploy1=$PHP_DEPLOYMENT_NAME is deployed" >> $GITHUB_OUTPUT

# oc get pods|grep $CRON_DEPLOYMENT_NAME
# sleep 30
# oc get pods -l deploymentconfig=$CRON_DEPLOYMENT_NAME --field-selector=status.phase=Running -o name
# sleep 20
# podNames=$(oc get pods -l deploymentconfig=$CRON_DEPLOYMENT_NAME --field-selector=status.phase=Running -o name)
# pwd
# echo "$CRON_DEPLOYMENT_NAME is deployed"
# echo "deploy2=$CRON_DEPLOYMENT_NAME is deployed" >> $GITHUB_OUTPUT

# Deploy backups (** moved to deploy.yml)
# helm repo add bcgov http://bcgov.github.io/helm-charts
# helm upgrade --install db-backup-storage bcgov/backup-storage

echo "Deployment complete."
