#!/bin/bash
#set -e # Exit on error

# Source the utility script
source ./openshift/scripts/_utils.sh

oc project $OC_PROJECT

export REDIS_STS_NAME="$REDIS_NAME-node"
export REDIS_STATS_NAME="$REDIS_NAME-stats"

# Create or update the ConfigMap
create_or_update_configmap "$REDIS_STATS_NAME" \
  "./config/redis/redis-stats.php"

# Delete existing Service for Redis proxy if it exists
delete_resource_if_exists "svc" "$REDIS_PROXY_NAME"

# Ensure resource values are set with defaults if missing
REDIS_REQUEST_CPU="${REDIS_REQUEST_CPU:-20m}"
REDIS_REQUEST_MEMORY="${REDIS_REQUEST_MEMORY:-128Mi}"
REDIS_LIMIT_CPU="${REDIS_LIMIT_CPU:-150m}"
REDIS_LIMIT_MEMORY="${REDIS_LIMIT_MEMORY:-256Mi}"

# Create a comprehensive values file for both install and upgrade
cat <<EOF > redis-values.yaml
global:
  defaultFips: false

fips:
  openssl: false

auth:
  enabled: false

persistence:
  enabled: false

redis:
  enableServiceLinks: false
  persistence:
    enabled: false
  resources:
    requests:
      cpu: $REDIS_REQUEST_CPU
      memory: $REDIS_REQUEST_MEMORY
    limits:
      cpu: $REDIS_LIMIT_CPU
      memory: $REDIS_LIMIT_MEMORY

replicas:
  replicaCount: $REDIS_REPLICAS
  persistence:
    enabled: false
  resources:
    requests:
      cpu: $REDIS_REQUEST_CPU
      memory: $REDIS_REQUEST_MEMORY
    limits:
      cpu: $REDIS_LIMIT_CPU
      memory: $REDIS_LIMIT_MEMORY

sentinel:
  enabled: true
  persistence:
    enabled: false
  resources:
    requests:
      cpu: $REDIS_REQUEST_CPU
      memory: $REDIS_REQUEST_MEMORY
    limits:
      cpu: $REDIS_LIMIT_CPU
      memory: $REDIS_LIMIT_MEMORY
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

# Define Redis-specific legacy image overrides with FIPS configuration
REDIS_LEGACY_ARGS="--set image.repository=bitnamilegacy/redis --set sentinel.image.repository=bitnamilegacy/redis-sentinel --set global.security.allowInsecureImages=true --set global.defaultFips=false --set fips.openssl=false"

create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
  "redis-values.yaml" \
  "redis-values.yaml" \
  "$REDIS_LEGACY_ARGS"

# Apply Redis probe fixes immediately after Helm deployment (before waiting for readiness)
echo "🔧 Applying Redis probe fixes before waiting for deployment readiness..."
apply_redis_probe_fixes "$redis_node_name" "$OC_PROJECT" 180

# Scale to desired replicas
scale_deployment "statefulset" "$redis_node_name" "$REDIS_REPLICAS" "$REDIS_REPLICAS"

# Now wait for the StatefulSet to be ready with the correct probe configurations
if ! wait_for "statefulset/$redis_node_name"; then
  echo "Failed to deploy Redis. Exiting..."
  exit 1
fi

# Create a service for each redis pod
create_redis_services "$REDIS_NAME"

# Wait for Redis nodes to sync
if ! wait_for_redis_sync "$redis_node_name" "$OC_PROJECT" 60 10; then
  echo "Redis nodes failed to sync. Exiting..."
  exit 1
fi

# Generate dynamic redis proxy config for the current environment
echo "🔧 Generating Redis proxy configuration for namespace: $OC_PROJECT"
dynamic_config_file="/tmp/sentinel_tunnel.${OC_PROJECT}.config.json"

# Set up cleanup trap
cleanup_temp_config() {
  if [[ -f "$dynamic_config_file" ]]; then
    echo "🧹 Cleaning up temporary config file: $dynamic_config_file"
    rm -f "$dynamic_config_file"
  fi
}
trap cleanup_temp_config EXIT

if ! generate_redis_proxy_config_json "$OC_PROJECT" "$REDIS_NAME-node" "redis-headless" 26379 "$dynamic_config_file"; then
  echo "❌ Failed to generate Redis proxy configuration. Exiting..."
  exit 1
fi

# Validate the generated configuration
echo "🔍 Validating generated Redis proxy configuration..."
if ! validate_redis_proxy_config "$dynamic_config_file" "$OC_PROJECT" "$REDIS_NAME-node"; then
  echo "❌ Generated Redis proxy configuration failed validation. Exiting..."
  exit 1
fi

# Create the ConfigMap with the validated dynamic config
echo "✅ Creating ConfigMap with validated Redis proxy configuration..."
create_or_update_configmap "$REDIS_PROXY_NAME-config" \
  "config.json=$dynamic_config_file"

# Deploy the Redis proxy
deploy_resource_from_template ./openshift/redis-proxy.yml \
  DEPLOY_IMAGE=${REDIS_PROXY_IMAGE} \
  REDIS_PROXY_NAME=$REDIS_PROXY_NAME
if ! wait_for "deployment/$REDIS_PROXY_NAME"; then
  echo "Failed to deploy Redis Proxy. Exiting..."
  exit 1
fi

# Deploy Redis Insight (removed due to security flags)
# echo "Deploying Redis Insight..."
# oc apply -f ./openshift/redis-insight.yml

# Verify Redis Proxy is ready and functional
echo "Waiting for Redis Proxy to be ready and functional..."
if ! wait_for_redis_proxy_ready "$REDIS_PROXY_NAME" "$OC_PROJECT" 60 10; then
  echo "❌ Redis Proxy failed to become ready and functional. Exiting..."
  exit 1
fi
echo "✔️ Redis Proxy is fully functional."
echo "✅ Redis deployment completed successfully!"
