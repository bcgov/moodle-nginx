#!/bin/bash

DEPLOYMENT_SELECTOR="deployment/$BUILD_NAME"
ROUTE_NAME="moodle-web"

# Source the utility script
source ./openshift/scripts/_utils.sh

# Check if the utility script is sourced correctly
if ! type deploy_resource_from_template &> /dev/null; then
  echo "Error: deploy_resource_from_template function not found. Ensure _utils.sh is sourced correctly."
  exit 1
fi

if ! type wait_for &> /dev/null; then
  echo "Error: wait_for function not found. Ensure _utils.sh is sourced correctly."
  exit 1
fi

# maintenance html page
create_or_update_configmap maintenance-page ./config/maintenance/index.html

# maintenance nginx config
create_or_update_configmap maintenance-config ./config/nginx/maintenance.conf=/etc/nginx/conf.d/default.conf

if [[ `oc describe $DEPLOYMENT_SELECTOR 2>&1` =~ "NotFound" ]]; then
  echo "$DEPLOYMENT_SELECTOR NOT FOUND: Beginning deployment..."
else
  echo "$DEPLOYMENT_SELECTOR Installation found...Scaling to 0..."
  oc scale $DEPLOYMENT_SELECTOR --replicas=0
  wait_for "$DEPLOYMENT_SELECTOR" "ready" "90s" "down"

  echo "Recreating $BUILD_NAME..."
  oc delete $DEPLOYMENT_SELECTOR -n $DEPLOY_NAMESPACE
  oc delete svc/$BUILD_NAME -n $DEPLOY_NAMESPACE

  sleep 5
fi

deploy_resource_from_template ./openshift/maintenance.yml \
  DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  WEB_IMAGE=$WEB_IMAGE \
  BUILD_NAME=$BUILD_NAME

# Wait for the deployment/to scale to 1
if ! wait_for "$DEPLOYMENT_SELECTOR" "ready" "500s"; then
  # If maintenance deployment failed
  # exit the deployment before changing the route
  echo "$DEPLOYMENT_SELECTOR failed. Exiting..."
  exit 1
fi

# Redirect traffic to maintenance-message
if ! oc get route "$ROUTE_NAME" &> /dev/null; then
  echo "⚠️ Route $ROUTE_NAME does not exist. Skipping route patch."
else
  patch_route $ROUTE_NAME $BUILD_NAME
fi
