#!/bin/bash

DEPLOYMENT_SELECTOR="deployment/$BUILD_NAME"

# Source the utility script
source ./openshift/scripts/_utils.sh

# maintenance html page
if [[ `oc describe configmap maintenance-page 2>&1` =~ "NotFound" ]]; then
  oc create configmap maintenance-page --from-file=./config/maintenance/index.html
else
  oc delete configmap maintenance-page
  oc create configmap maintenance-page --from-file=./config/maintenance/index.html
fi

# maintenance nginx config
if [[ `oc describe configmap maintenance-config 2>&1` =~ "NotFound" ]]; then
  oc create configmap maintenance-config --from-file=default.conf=./config/nginx/maintenance.conf
else
  oc delete configmap maintenance-config
  oc create configmap maintenance-config --from-file=default.conf=./config/nginx/maintenance.conf
fi

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

# oc process -f ./openshift/maintenance.yml \
#   -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
#   -p WEB_IMAGE=$WEB_IMAGE \
#   -p BUILD_NAME=$BUILD_NAME \
#   | oc create -f -

# Wait for the deployment/to scale to 1
if ! wait_for "$DEPLOYMENT_SELECTOR" "ready" "500s"; then
  # If maintenance deployment failed
  # exit the deployment before changing the route
  echo "$DEPLOYMENT_SELECTOR failed. Exiting..."
  exit 1
fi

# Redirect traffic to maintenance-message
patch_route $ROUTE_NAME $BUILD_NAME
