#!/bin/bash
set -e # Exit on error

route_name=$REDIS_NAME
if [[ `oc describe route $route_name 2>&1` =~ "NotFound" ]]; then
  echo "Route NOT FOUND: $route_name - Skipping..."
else
  echo "$route_name route FOUND: Cleaning resources..."
  oc delete route $route_name
  echo "DELETED route:  $route_name"
fi

# Find and delete all services
echo "Delete Redis Services ..."
if [[ `oc describe svc/$REDIS_NAME 2>&1` =~ "NotFound" ]]; then
  echo "Service NOT FOUND: $REDIS_NAME - Skipping..."
else
  echo "$REDIS_NAME service FOUND: Cleaning resources..."
  oc delete svc/$REDIS_NAME
  echo "DELETED service:  $REDIS_NAME"
fi

SERVICES=$(oc get svc -l name=redis -o jsonpath='{.items[*].metadata.name}')
for service in $SERVICES; do
  if [[ `oc describe svc/$service 2>&1` =~ "NotFound" ]]; then
    echo "Service NOT FOUND: $service - Skipping..."
  else
    echo "$service service FOUND: Cleaning resources..."
    oc delete svc/$service
    echo "DELETED service:  $service"
  fi
done

if [[ `oc describe configmap/$REDIS_NAME-config-map 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap NOT FOUND: $REDIS_NAME-config-map - Skipping..."
else
  echo "$REDIS_NAME-config-map FOUND: Cleaning resources..."
  oc delete configmap/$REDIS_NAME-config-map
  echo "DELETED configmap:  $REDIS_NAME-config-map"
fi

if [[ `oc describe configmap/$REDIS_NAME-stats 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap NOT FOUND: $REDIS_NAME-stats - Skipping..."
else
  echo "$REDIS_NAME-stats FOUND: Cleaning resources..."
  oc delete configmap/$REDIS_NAME-stats
  echo "DELETED configmap:  $REDIS_NAME-stats"
fi

if [[ `oc describe sts/$REDIS_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$REDIS_NAME StatefulSet NOT FOUND - Skipping..."
else
  echo "$REDIS_NAME StatefulSet FOUND: Cleaning resources..."
  oc delete sts/$REDIS_NAME
  echo "DELETED StatefulSet:  $REDIS_NAME"
fi

echo "Creating configMap: $REDIS_NAME-config"
sed -e "s/\${REDIS_PASSWORD}/$REDIS_PASSWORD/g" < ./config/redis/redis-config.yml | oc apply -f -

echo "Creating configMap: $REDIS_NAME-stats"
oc create configmap $REDIS_NAME-stats --from-file=./config/redis/redis-stats.php

# Create a headless service to control the domain of the Redis cluster
oc create service clusterip $REDIS_NAME --tcp=6379:6379 -n $DEPLOY_NAMESPACE``

# Create a StatefulSet for Redis
echo "Deploy Redis to OpenShift ($REDIS_IMAGE) ..."
sed -e "s/\${REDIS_NAME}/$REDIS_NAME/g" -e "s/\${REDIS_IMAGE}/$REDIS_IMAGE/g" -e "s/\${REDIS_REPLICAS}/$REDIS_REPLICAS/g" < ./openshift/redis-sts.yml | oc apply -f -

# Expose the service
oc expose svc/$REDIS_NAME -n $DEPLOY_NAMESPACE
