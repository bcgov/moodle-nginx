#!/bin/bash
set -e # Exit on error

route_name=$REDIS_DEPLOYMENT_NAME
if [[ `oc describe route $route_name 2>&1` =~ "NotFound" ]]; then
  echo "Route NOT FOUND: $route_name - Skipping..."
else
  echo "$route_name route FOUND: Cleaning resources..."
  oc delete route $route_name
  echo "DELETED route:  $route_name"
fi

if [[ `oc describe svc/$route_name 2>&1` =~ "NotFound" ]]; then
  echo "Service NOT FOUND: $route_name - Skipping..."
else
  echo "$route_name service FOUND: Cleaning resources..."
  oc delete svc/$route_name
  echo "DELETED service:  $route_name"
fi

if [[ `oc describe configmap $REDIS_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap NOT FOUND: $REDIS_DEPLOYMENT_NAME - Skipping..."
else
  echo "$REDIS_DEPLOYMENT_NAME configmap FOUND: Cleaning resources..."
  oc delete configmap $REDIS_DEPLOYMENT_NAME-config
  echo "DELETED configmap:  $REDIS_DEPLOYMENT_NAME-config"
fi

if [[ `oc describe sts/$REDIS_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$REDIS_DEPLOYMENT_NAME StatefulSet NOT FOUND - Skipping..."
else
  echo "$REDIS_DEPLOYMENT_NAME StatefulSet FOUND: Cleaning resources..."
  oc delete sts/$REDIS_DEPLOYMENT_NAME
  echo "DELETED StatefulSet:  $REDIS_DEPLOYMENT_NAME"
fi

echo "Creating configMap: $REDIS_DEPLOYMENT_NAME-config"
oc apply -f ./config/redis/redis-config.yml

# Create a headless service to control the domain of the Redis cluster
oc create service clusterip $REDIS_DEPLOYMENT_NAME --tcp=6379:6379 -n $DEPLOY_NAMESPACE``

# Create a StatefulSet for Redis
echo "Deploy Redis to OpenShift ($REDIS_IMAGE) ..."
envsubst < ./openshift/redis-sts.yml | oc apply -f -

# export VARS_TO_SUBST="$(env | cut -d= -f1 | grep -v '^ordinal$' | grep -v '^host$' | sed -e 's/^/${/' -e 's/$/}/' | tr '\n' ' ')"
envsubst "${REDIS_DEPLOYMENT_NAME},${REDIS_IMAGE}" < ./openshift/redis-sts.yml | oc apply -f -

# Expose the service
oc expose svc/$REDIS_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE
