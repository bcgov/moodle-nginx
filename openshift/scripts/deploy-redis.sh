#!/bin/bash

$route_name=$REDIS_DEPLOYMENT_NAME
if [[ `oc describe route $route_name 2>&1` =~ "NotFound" ]]; then
  echo "Route NOT FOUND: $route_name - Skipping..."
else
  echo "$route_name FOUND: Cleaning resources..."
  oc delete route $route_name
  echo "DELETED route:  $route_name"
fi

if [[ `oc describe svc/$route_name 2>&1` =~ "NotFound" ]]; then
  echo "Service NOT FOUND: $route_name - Skipping..."
else
  echo "$route_name FOUND: Cleaning resources..."
  oc delete svc/$route_name
  echo "DELETED service:  $route_name"
fi

# Create a headless service to control the domain of the Redis cluster
oc create service clusterip $REDIS_DEPLOYMENT_NAME --tcp=6379:6379 -n $DEPLOY_NAMESPACE``

# Create a StatefulSet for Redis
echo "Deploy Redis to OpenShift ..."
envsubst < ./openshift/redis.yml | oc apply -f -

# Expose the service
oc expose svc/$REDIS_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE
