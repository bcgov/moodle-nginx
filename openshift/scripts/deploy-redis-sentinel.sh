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
    enabled: true
    size: 50Mi
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
    enabled: true
    size: 5Mi
auth:
  enabled: false
  sentinel: false
  password: ""
  usePasswordFileFromSecret: false
EOF

# Create minimal file for updates (or it will fail)
cat <<EOF > upgrade.yaml
replicas:
  replicaCount: $REDIS_REPLICAS
  persistence:
    enabled: true
    size: 50Mi
EOF

# Create or update the Helm deployment
helm repo add bitnami https://charts.bitnami.com/bitnami
create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
  "values.yaml" \
  "upgrade.yaml"
wait_for "statefulset/$REDIS_NAME"

# Create a service for each redis pod
create_redis_services "$REDIS_NAME"

# Deploy the Redis proxy
deploy_resource_from_template "./openshift/redis-proxy.yml" \
  "DEPLOY_IMAGE=$REDIS_PROXY_IMAGE" \
  "REDIS_PROXY_NAME=$REDIS_PROXY_NAME"
wait_for "deployment/$REDIS_PROXY_NAME"

# Deploy Redis Insight
echo "Deploying Redis Insight..."
oc apply -f ./openshift/redis-insight.yml
