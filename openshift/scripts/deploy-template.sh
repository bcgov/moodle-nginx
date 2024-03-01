test -n "$DEPLOY_NAMESPACE"
test -n "$BRANCH"
echo "Current namespace is $DEPLOY_NAMESPACE"

# Create ConfigMaps
oc create configmap $WEB_DEPLOYMENT_NAME-config --from-file=./config/nginx/default.conf
oc create configmap $APP-config --from-file=config.php=./config/moodle/$MOODLE_ENVIRONMENT.config.php
oc create configmap $CRON_DEPLOYMENT_NAME-config --from-file=config.php=./config/cron/$MOODLE_ENVIRONMENT.config.php

oc -n $DEPLOY_NAMESPACE process -f ./openshift/template.json \
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
oc -n $DEPLOY_NAMESPACE apply -f -

# echo "Rolling out $MOODLE_DEPLOYMENT_NAME..."
# oc rollout latest dc/$MOODLE_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE

echo "Rolling out $PHP_DEPLOYMENT_NAME..."
oc rollout latest dc/$PHP_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE

# echo "Rolling out $CRON_DEPLOYMENT_NAME..."
# oc rollout latest dc/$CRON_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE

# Check PHP deployment rollout status until complete.
ATTEMPTS=0
WAIT_TIME=5
ROLLOUT_STATUS_CMD="oc rollout status dc/$PHP_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE"
until $ROLLOUT_STATUS_CMD || [ $ATTEMPTS -eq 120 ]; do
  $ROLLOUT_STATUS_CMD
  ATTEMPTS=$((attempts + 1))
  echo "Waited: $(($ATTEMPTS * $WAIT_TIME)) seconds..."
  sleep $WAIT_TIME
done

# Check Moodle deployment rollout status until complete.
# ATTEMPTS=0
# WAIT_TIME=5
# ROLLOUT_STATUS_CMD="oc rollout status dc/$MOODLE_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE"
# until $ROLLOUT_STATUS_CMD || [ $ATTEMPTS -eq 120 ]; do
#   $ROLLOUT_STATUS_CMD
#   ATTEMPTS=$((attempts + 1))
#   echo "Waited: $(($ATTEMPTS * $WAIT_TIME)) seconds..."
#   sleep $WAIT_TIME
# done

# Enable Maintenance mode (PHP)
echo "Enabling Moodle maintenance mode..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/maintenance.php --enable' -n $DEPLOY_NAMESPACE --wait

echo "Create and run Moodle build migration job..."
oc process -f ./openshift/migrate-build-files-job.yml | oc create -f -

echo "Waiting for Moodle build migration job status to complete..."
ATTEMPTS=0
WAIT_TIME=5
MIGRATE_STATUS_CMD="oc get jobs | findstr /i 'migrate-build-files 1/1'"
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
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c 'rm -f /var/www/html/config.php' -n $DEPLOY_NAMESPACE

# MOODLE_APP_DIR=/var/www/html

# # Delete existing plugins (PHP)
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/admin/tool/trigger" -n $DEPLOY_NAMESPACE
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/admin/tool/dataflows" -n $DEPLOY_NAMESPACE
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/facetoface" -n $DEPLOY_NAMESPACE
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/hvp" -n $DEPLOY_NAMESPACE
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/course/format/topcoll" -n $DEPLOY_NAMESPACE
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/customcert" -n $DEPLOY_NAMESPACE
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c "rm -f $MOODLE_APP_DIR/mod/certificate" -n $DEPLOY_NAMESPACE

# # Copy / update all files from docker build to shared PVC (Moodle)
# oc exec dc/$MOODLE_DEPLOYMENT_NAME -- bash -c 'cp -ru /app/public/* /var/www/html' -n $DEPLOY_NAMESPACE

echo "Purging caches..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/purge_caches.php' -n $DEPLOY_NAMESPACE

echo "Purging missing plugins..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/uninstall_plugins.php --purge-missing --run' -n $DEPLOY_NAMESPACE

echo "Running Moodle upgrades..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/upgrade.php --non-interactive' -n $DEPLOY_NAMESPACE

echo "Disabling maintenance mode..."
oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/maintenance.php --disable' -n $DEPLOY_NAMESPACE


echo "Create and run Moodle cron job..."
oc process -f ./openshift/moodle-cron-job.yml | oc create -f -

# echo "Run first cron..."
# oc exec dc/$PHP_DEPLOYMENT_NAME -- bash -c 'php /var/www/html/admin/cli/cron.php' -n $DEPLOY_NAMESPACE

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
