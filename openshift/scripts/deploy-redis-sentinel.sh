#!/bin/bash
#set -e # Exit on error

# Source the utility script
source ./openshift/scripts/_utils.sh

oc project $OC_PROJECT

export REDIS_STS_NAME="$REDIS_NAME-node"
export REDIS_STATS_NAME="$REDIS_NAME-stats"

# Create or update the ConfigMap for Redis stats
create_or_update_configmap "$REDIS_STATS_NAME" \
  "./config/redis/redis-stats.php"

# Delete existing Service for Redis proxy if it exists
delete_resource_if_exists "svc" "$REDIS_PROXY_NAME"

# Create the ConfigMap for Redis proxy
create_or_update_configmap "$REDIS_PROXY_NAME-config" \
  "config.json=./config/redis/sentinel_tunnel.remote.config.json"

# Create a temporary values file
cat <<EOF > values.yaml
global:
  redis:
    password: ""
replicas:
  replicaCount: $REDIS_REPLICAS
  persistence:
    enabled: false
  resources:
    requests:
      cpu: $REDIS_REQUEST_CPU
      memory: $REDIS_REQUEST_MEMORY
    limits:
      cpu: null
      memory: null
sentinel:
  enabled: true
  persistence:
    enabled: false
    size: 5Mi
auth:
  enabled: false
  sentinel: false
  password: ""
  usePasswordFileFromSecret: false
EOF

# Create minimal file for updates (or it will fail)
cat <<EOF > upgrade.yaml
redis:
  persistence:
    enabled: false
    size: 600Mi
  resources:
    requests:
      memory: 128Mi
      cpu: 100m
replicas:
  replicaCount: $REDIS_REPLICAS
  persistence:
    enabled: false
sentinel:
  enabled: true
  externalAccess:
    enabled: false
  automateClusterRecovery: true
  persistence:
    enabled: false
    size: 0Mi
  resources:
    requests:
      memory: 32Mi
      cpu: 5m
EOF

# Scale down the Redis deployment if it exists
if [[ `oc describe statefulset/$REDIS_NAME 2>&1` =~ "NotFound" ]]; then
  echo "Redis StatefulSet NOT FOUND... Creating new deployment..."
else
  echo "Redis StatefulSet found. Scaling down..."
  scale_deployment "statefulset" "$REDIS_NAME" "0" "0"
  if ! wait_for "statefulset/$REDIS_NAME" "ready" "120s" "down"; then
    echo "Failed to scale $REDIS_NAME to 0 replicas. Exiting..."
    exit 1
  fi
fi

# Delete existing PVCs for Redis if they exist
# Removed sectin due to using Memory for Redis rateher than PVC
# Loop through a list of PVC's, by incrementing the index
# pvc_name="redis-data-redis-node-"
# for i in $(seq 0 $((REDIS_REPLICAS - 1))); do
#   indexed_pvc_name="${pvc_name}-${i}"
#   delete_resource_if_exists "pvc" "$indexed_pvc_name"
#   if [[ `oc describe pvc/$indexed_pvc_name 2>&1` =~ "NotFound" ]]; then
#     echo "PVC $indexed_pvc_name NOT FOUND..."
#   else
#     echo "Deleting PVC $indexed_pvc_name..."
#     oc delete pvc $indexed_pvc_name
#   fi
# done

# Create or update the Helm deployment
helm repo add bitnami https://charts.bitnami.com/bitnami
create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
  "values.yaml" \
  "upgrade.yaml"
if ! wait_for "statefulset/$REDIS_NAME"; then
  echo "Failed to deploy Redis. Exiting..."
  exit 1
fi

scale_deployment "statefulset" "$REDIS_NAME-node" "$REDIS_REPLICAS" "$REDIS_REPLICAS"

# Create a service for each redis pod
create_redis_services "$REDIS_NAME"

# Deploy the Redis proxy
deploy_resource_from_template ./openshift/redis-proxy.yml \
  DEPLOY_IMAGE=$REDIS_PROXY_IMAGE \
  REDIS_PROXY_NAME=$REDIS_PROXY_NAME
if ! wait_for "deployment/$REDIS_PROXY_NAME"; then
  echo "Failed to deploy Redis Proxy. Exiting..."
  exit 1
fi

# Deploy Redis Insight
echo "Deploying Redis Insight..."
oc apply -f ./openshift/redis-insight.yml
