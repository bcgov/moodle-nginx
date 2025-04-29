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

# Generate dynamic sentinel config for the current environment
generate_sentinel_config_json "$OC_PROJECT" "$REDIS_NAME-node" "redis-headless" 26379 "./config/redis/sentinel_tunnel.remote.config.json"

# Create the ConfigMap for Redis proxy with the generated config
create_or_update_configmap "$REDIS_PROXY_NAME-config" \
  "config.json=./config/redis/sentinel_tunnel.remote.config.json"

# Create a temporary values file
cat <<EOF > install.yaml
global:
  redis:
    password: ""
resources:
  requests:
    cpu: $REDIS_REQUEST_CPU
    memory: $REDIS_REQUEST_MEMORY
  limits:
    cpu: null
    memory: null
persistence:
  enabled: false
  storageClass: "-"
  storageClassName: "-"
  size: 0Mi
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
  resources:
    requests:
      cpu: $REDIS_REQUEST_CPU
      memory: $REDIS_REQUEST_MEMORY
    limits:
      cpu: null
      memory: null
auth:
  enabled: false
  sentinel: false
  password: ""
  usePasswordFileFromSecret: false
EOF

# Create minimal file for updates (or it will fail)
cat <<EOF > upgrade.yaml
persistence:
  enabled: false
  storageClass: "-"
  storageClassName: "-"
  size: 0Mi
resources:
  requests:
    cpu: $REDIS_REQUEST_CPU
    memory: $REDIS_REQUEST_MEMORY
  limits:
    cpu: null
    memory: null
redis:
  persistence:
    enabled: false
    storageClass: "-"
    storageClassName: "-"
    size: 0Mi
  resources:
    requests:
      memory: $REDIS_REQUEST_MEMORY
      cpu: $REDIS_REQUEST_CPU
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
    storageClass: "-"
    storageClassName: "-"
    size: 0Mi
  resources:
    requests:
      memory: 32Mi
      cpu: 5m
EOF

# Scale down the Redis deployment if it exists
redis_node_name=$REDIS_NAME-node
if [[ `oc describe statefulset/$redis_node_name 2>&1` =~ "NotFound" ]]; then
  echo "Redis StatefulSet NOT FOUND... Creating new deployment..."
else
  echo "Redis StatefulSet found. Scaling down..."
  scale_deployment "statefulset" "$redis_node_name" "0" "0"
  if ! wait_for "statefulset/$redis_node_name" "ready" "120s" "down"; then
    echo "Failed to scale $redis_node_name to 0 replicas. Exiting..."
    exit 1
  fi
fi

# Create or update the Helm deployment
helm repo add bitnami https://charts.bitnami.com/bitnami
create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
  "install.yaml" \
  "upgrade.yaml"
if ! wait_for "statefulset/$redis_node_name"; then
  echo "Failed to deploy Redis. Exiting..."
  exit 1
fi

scale_deployment "statefulset" "$redis_node_name" "$REDIS_REPLICAS" "$REDIS_REPLICAS"

# Create a service for each redis pod
create_redis_services "$REDIS_NAME"

# Wait for Redis nodes to sync
if ! wait_for_redis_sync "$redis_node_name" "$OC_PROJECT" 60 10; then
  echo "Redis nodes failed to sync. Exiting..."
  exit 1
fi

# Deploy the Redis proxy
deploy_resource_from_template ./openshift/redis-proxy.yml \
  DEPLOY_IMAGE=${REDIS_PROXY_IMAGE} \
  REDIS_PROXY_NAME=$REDIS_PROXY_NAME
if ! wait_for "deployment/$REDIS_PROXY_NAME"; then
  echo "Failed to deploy Redis Proxy. Exiting..."
  exit 1
fi

# Deploy Redis Insight
echo "Deploying Redis Insight..."
oc apply -f ./openshift/redis-insight.yml

# Verify Redis Proxy is ready and functional
echo "Waiting for Redis Proxy to be ready and functional..."
if ! wait_for_redis_proxy_ready "$REDIS_PROXY_NAME" "$OC_PROJECT" 60 10; then
  echo "❌ Redis Proxy failed to become ready and functional. Exiting..."
  exit 1
fi
echo "✔️ Redis Proxy is fully functional."
