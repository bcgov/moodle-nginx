#!/bin/bash

# Create a headless service to control the domain of the Redis cluster
oc create service clusterip $REDIS_DEPLOYMENT_NAME --tcp=6379:6379 -n $DEPLOY_NAMESPACE

export REDIS_IMAGE=$REDIS_IMAGE
export REDIS_DEPLOYMENT_NAME=$REDIS_DEPLOYMENT_NAME
export REPLICAS=$REPLICAS

# Create a StatefulSet for Redis
echo "Deploy Redis to OpenShift ..."
envsubst < ./openshift/redis.yml | oc apply -f -

# Expose the service
oc expose svc/$REDIS_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE
