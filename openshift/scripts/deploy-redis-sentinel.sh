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
  security:
    allowInsecureImages: true

fips:
  openssl: false

# Use proven working image tags from test environment
image:
  repository: bitnamilegacy/redis
  tag: 8.0.2-debian-12-r2
  debug: false

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
  image:
    repository: bitnamilegacy/redis-sentinel
    tag: 8.0.2-debian-12-r1
  persistence:
    enabled: false
  resources:
    requests:
      cpu: $REDIS_REQUEST_CPU
      memory: $REDIS_REQUEST_MEMORY
    limits:
      cpu: $REDIS_LIMIT_CPU
      memory: $REDIS_LIMIT_MEMORY

# Alternative FIPS structure for older chart versions
commonConfiguration: |
  fips-mode no
EOF

# Scale down the Redis deployment if it exists
redis_node_name=$REDIS_NAME-node
if [[ `oc describe statefulset/$redis_node_name 2>&1` =~ "NotFound" ]]; then
  echo "Redis StatefulSet NOT FOUND... Creating new deployment..."
else
  echo "Redis StatefulSet found. Checking if image update requires Helm reinstall..."

  # Get current image tags from the StatefulSet
  current_redis_image=$(oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[?(@.name=="redis")].image}' 2>/dev/null || echo "")
  current_sentinel_image=$(oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[?(@.name=="sentinel")].image}' 2>/dev/null || echo "")

  echo "Current images:"
  echo "  Redis: $current_redis_image"
  echo "  Sentinel: $current_sentinel_image"

  target_redis_image="bitnamilegacy/redis:8.0.2-debian-12-r2"
  target_sentinel_image="bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1"

  # Check if image changes require Helm reinstall
  if [[ "$current_redis_image" != *"$target_redis_image"* ]] || [[ "$current_sentinel_image" != *"$target_sentinel_image"* ]]; then
    echo "Image tags have changed. Helm reinstall required to handle StatefulSet recreation..."
    echo "Scaling down existing StatefulSet before Helm uninstall..."

    scale_deployment "statefulset" "$redis_node_name" "0" "0"
    if ! wait_for "statefulset/$redis_node_name" "ready" "120s" "down"; then
      echo "Failed to scale $redis_node_name to 0 replicas. Exiting..."
      exit 1
    fi

    # Use Helm to uninstall and reinstall to properly handle StatefulSet changes
    echo "Uninstalling Helm release to allow clean recreation..."
    helm uninstall "$REDIS_NAME" || echo "Helm release may not exist, continuing..."

    # Wait for cleanup
    echo "Waiting for resources to be cleaned up..."
    sleep 10

    # Set flag to force install instead of upgrade
    FORCE_HELM_INSTALL=true
  else
    echo "Image tags unchanged. Performing standard scaling..."
    scale_deployment "statefulset" "$redis_node_name" "0" "0"
    if ! wait_for "statefulset/$redis_node_name" "ready" "120s" "down"; then
      echo "Failed to scale $redis_node_name to 0 replicas. Exiting..."
      exit 1
    fi
  fi
fi

# Create or update the Helm deployment
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

echo "🔍 Debug: Redis Helm chart information:"
helm search repo bitnami/redis --versions | head -5

# Pin to chart version that works in dev/test environments
REDIS_CHART_VERSION="23.1.3"
echo "🔧 Using Redis chart version: $REDIS_CHART_VERSION"

echo "🔍 Debug: Checking generated redis-values.yaml file..."
echo "--- FIPS Configuration ---"
grep -A 5 -B 5 "Fips\|fips" redis-values.yaml || echo "No FIPS configuration found in values file"
echo "--- End FIPS Configuration ---"

# Define Redis-specific legacy image overrides with FIPS configuration
# Use proven working image tags from test environment
REDIS_LEGACY_ARGS="--set image.repository=bitnamilegacy/redis"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set image.tag=8.0.2-debian-12-r2"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set sentinel.image.repository=bitnamilegacy/redis-sentinel"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set sentinel.image.tag=8.0.2-debian-12-r1"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set global.security.allowInsecureImages=true"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set global.defaultFips=false"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set fips.openssl=false"
# Configure probes with delays matching test environment (don't disable completely)
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set redis.startupProbe.enabled=false"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set sentinel.startupProbe.enabled=false"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set redis.livenessProbe.enabled=true"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set sentinel.livenessProbe.enabled=true"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set redis.readinessProbe.enabled=true"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set sentinel.readinessProbe.enabled=true"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set redis.livenessProbe.initialDelaySeconds=180"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set redis.readinessProbe.initialDelaySeconds=180"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set sentinel.livenessProbe.initialDelaySeconds=180"
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --set sentinel.readinessProbe.initialDelaySeconds=180"

echo "🔍 Debug: Using image versions matching test environment:"
echo "  Redis: bitnamilegacy/redis:8.0.2-debian-12-r2"
echo "  Sentinel: bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1"
echo "🔧 Startup probes disabled, liveness/readiness probes enabled with 180s delay"

echo "🔍 Debug: Helm command will use these --set arguments:"
echo "$REDIS_LEGACY_ARGS"

# Use specific chart version and add version to the legacy args
REDIS_LEGACY_ARGS="$REDIS_LEGACY_ARGS --version $REDIS_CHART_VERSION"

# Handle forced reinstall for StatefulSet image changes
if [[ "$FORCE_HELM_INSTALL" == "true" ]]; then
  echo "🔧 Performing Helm install (forced due to image changes)..."
  helm install --values redis-values.yaml $REDIS_LEGACY_ARGS "$REDIS_NAME" "$REDIS_HELM_CHART"
else
  echo "🔧 Performing standard Helm upgrade..."
  create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
    "redis-values.yaml" \
    "redis-values.yaml" \
    "$REDIS_LEGACY_ARGS"
fi

# Debug: Check actual probe configuration in the deployed StatefulSet
echo "🔍 Debug: Checking actual probe configuration in StatefulSet..."
oc get statefulset/$redis_node_name -o yaml | grep -A 20 -B 5 "Probe:" || echo "No probes found (good!)"

# Scale to desired replicas
scale_deployment "statefulset" "$redis_node_name" "$REDIS_REPLICAS" "$REDIS_REPLICAS"

# Now wait for the StatefulSet to be ready with the correct probe configurations
echo "🔍 Monitoring Redis container startup..."
if ! wait_for "statefulset/$redis_node_name"; then
  echo "❌ Failed to deploy Redis. Checking container status..."

  # Get pod status and logs for debugging
  pod_name="${redis_node_name}-0"
  echo "🔍 Debug: Pod status for $pod_name:"
  oc describe pod "$pod_name" | grep -A 10 -B 10 "State\|Conditions\|Events"

  echo "🔍 Debug: Recent Redis container logs:"
  oc logs "$pod_name" -c redis --tail=20 || echo "Cannot get Redis logs"

  echo "🔍 Debug: Recent Sentinel container logs:"
  oc logs "$pod_name" -c sentinel --tail=20 || echo "Cannot get Sentinel logs"

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
