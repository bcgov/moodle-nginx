#!/bin/bash
set -e # Exit on error

oc project $OC_PROJECT

export REDIS_STS_NAME="$REDIS_NAME-node"
export REDIS_STATS_NAME="$REDIS_NAME-stats"

if [[ `oc describe configmap/$REDIS_STATS_NAME 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap NOT FOUND: $REDIS_STATS_NAME"
else
  echo "$REDIS_STATS_NAME ConfigMap FOUND: Cleaning resources..."
  oc delete configmap/$REDIS_STATS_NAME
  echo "DELETED ConfigMap: $REDIS_STATS_NAME"
fi
echo "Creating ConfigMap: $REDIS_STATS_NAME"
oc create configmap $REDIS_STATS_NAME --from-file=./config/redis/redis-stats.php

helm repo add bitnami https://charts.bitnami.com/bitnami

# Create a temporary values file
cat <<EOF > values.yaml
global:
  redis:
    password: ""
replica:
  replicaCount: $REDIS_REPLICAS
  persistence:
    enabled: true
    size: 500Mi
sentinel:
  enabled: true
  persistence:
    enabled: true
    size: 20Mi
auth:
  enabled: false
  sentinel: false
  password: ""
  usePasswordFileFromSecret: false
EOF

# Check if the Helm deployment exists
if helm list -q | grep -q "^$REDIS_NAME$"; then
  echo "Helm deployment found. Updating..."
  # Removed: --set auth.password="$SECRET_REDIS_PASSWORD"
  helm_upgrade_response=$(helm upgrade $REDIS_NAME $REDIS_HELM_CHART --reuse-values -f values.yaml)

  # Output the response for debugging purposes
  echo "1. $helm_upgrade_response"

  # Check if the helm upgrade command failed
  if [[ $? -ne 0 ]]; then
    echo "Helm upgrade failed with the following output:"
    echo "2. $helm_upgrade_response"
    exit 1
  fi

  # Upgrade the Helm deployment with the new values
  if [[ $helm_upgrade_response =~ "Error" ]]; then
    echo "❌ Helm upgrade FAILED."
    echo "3. $helm_upgrade_response"
    exit 1
  fi

  if [[ `oc describe sts/$REDIS_STS_NAME 2>&1` =~ "NotFound" ]]; then
    echo "Helm chart ($REDIS_NAME) exists, but StatefulSet ($REDIS_STS_NAME) was NOT FOUND."
    exit 1
  fi
else
  echo "Helm deployment ($REDIS_NAME) NOT FOUND. Beginning deployment..."
  # Removed: --set auth.password="$SECRET_REDIS_PASSWORD"
  helm install $REDIS_NAME $REDIS_HELM_CHART --values values.yaml
fi

# Clean up the temporary values file
rm values.yaml

echo "Helm updates completed for $REDIS_NAME."

sleep 10

if [[ ! `oc describe configmap $REDIS_PROXY_NAME-config 2>&1` =~ "NotFound" ]]; then
  echo "ConfigMap exists... Deleting: $REDIS_PROXY_NAME-config"
  oc delete configmap $REDIS_PROXY_NAME-config
fi

sleep 10

echo "Creating configMap: $REDIS_PROXY_NAME-config"
oc create configmap $REDIS_PROXY_NAME-config --from-file=config.json=./config/redis/sentinel_tunnel.remote.config.json

sleep 10

echo "Deploying $REDIS_PROXY_NAME..."
if [[ `oc describe deployment/$REDIS_PROXY_NAME 2>&1` =~ "NotFound" ]]; then
  echo "deployment/$REDIS_PROXY_NAME job NOT FOUND..."
else
  # If the proxy exists, delete it
  echo "deployment/$REDIS_PROXY_NAME job found... deleting..."
  oc delete deployment/$REDIS_PROXY_NAME
  sleep 20
fi

# Deploy the Redis proxy
oc process -f ./openshift/redis-proxy.yml \
  -p DEPLOY_IMAGE=$REDIS_PROXY_IMAGE \
  -p REDIS_PROXY_NAME=$REDIS_PROXY_NAME \
  | oc create -f -

# Set best-effort resource limits for the deployment
# echo "Setting best-effort resource limits for the deployment..."
# oc set resources sts/$REDIS_STS_NAME --limits=cpu=0,memory=0 --requests=cpu=0,memory=0

echo "Deploying Redis Insight..."
oc apply -f ./openshift/redis-insight.yml
