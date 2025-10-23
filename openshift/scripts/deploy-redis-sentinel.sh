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

# Pin to chart version that works in dev/test environments
REDIS_CHART_VERSION="23.1.3"

# Configure Redis deployment arguments in one place
REDIS_ARGS=(
  "--set" "image.repository=bitnamilegacy/redis"
  "--set" "image.tag=8.0.2-debian-12-r2"
  "--set" "sentinel.image.repository=bitnamilegacy/redis-sentinel"
  "--set" "sentinel.image.tag=8.0.2-debian-12-r1"
  "--set" "global.security.allowInsecureImages=true"
  "--set" "redis.resources.limits.ephemeral-storage=2Gi"
  "--set" "redis.resources.requests.ephemeral-storage=50Mi"
  "--set" "persistence.enabled=false"
  "--set" "replica.persistence.enabled=false"
  "--set" "master.persistence.enabled=false"
  "--set" "sentinel.persistence.enabled=false"
  "--version" "$REDIS_CHART_VERSION"
)

# Create a minimal values file matching test environment
cat <<EOF > redis-values.yaml
global:
  security:
    allowInsecureImages: true

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
  enableServiceLinks: true
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

  echo "Target images:"
  echo "  Redis: $target_redis_image"
  echo "  Sentinel: $target_sentinel_image"

  # Check if changes require Helm reinstall (images or persistence settings)
  if [[ "$current_redis_image" != *"$target_redis_image"* ]] || [[ "$current_sentinel_image" != *"$target_sentinel_image"* ]]; then
    echo "🔍 Decision: Image tags have changed - Redis match: $([[ "$current_redis_image" == *"$target_redis_image"* ]] && echo "YES" || echo "NO"), Sentinel match: $([[ "$current_sentinel_image" == *"$target_sentinel_image"* ]] && echo "YES" || echo "NO")"
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
  # Also check if persistent volume claims exist (indicating persistence was enabled)
  elif oc get pvc -l app.kubernetes.io/name=redis &> /dev/null; then
    echo "Persistent volume claims detected. Helm reinstall required to disable persistence..."
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
    echo "Image tags unchanged and no persistence detected. Performing standard scaling..."
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

echo "🔧 Using Redis chart version: $REDIS_CHART_VERSION"

echo "🔍 Debug: Checking generated redis-values.yaml file..."
echo "--- FIPS Configuration ---"
grep -A 5 -B 5 "Fips\|fips" redis-values.yaml || echo "No FIPS configuration found in values file"
echo "--- End FIPS Configuration ---"

echo "🔍 Debug info:"
echo "  Redis: bitnamilegacy/redis:8.0.2-debian-12-r2"
echo "  Sentinel: bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1"
echo "🔧 Chart: $REDIS_CHART_VERSION"

echo "🔍 Debug: Helm deployment arguments:"
printf '%s\n' "${REDIS_ARGS[@]}"

# Handle forced reinstall for StatefulSet image changes
if [[ "$FORCE_HELM_INSTALL" == "true" ]]; then
  echo "🔧 Performing Helm install (forced due to image/persistence changes)..."
  echo "🔍 Debug: Checking if StatefulSet still exists before install..."
  if oc get statefulset "$redis_node_name" &> /dev/null; then
    echo "⚠️  WARNING: StatefulSet still exists after uninstall. Waiting for complete cleanup..."
    # Wait a bit more for cleanup
    sleep 15
    if oc get statefulset "$redis_node_name" &> /dev/null; then
      echo "❌ StatefulSet still exists. Manual cleanup may be required."
      echo "🔍 Current StatefulSet status:"
      oc get statefulset "$redis_node_name" -o wide
    fi
  fi

  helm install --values redis-values.yaml "${REDIS_ARGS[@]}" "$REDIS_NAME" "$REDIS_HELM_CHART"
else
  echo "🔧 Performing standard Helm upgrade..."
  # Convert array to string for create_or_update_helm_deployment
  REDIS_ARGS_STRING="${REDIS_ARGS[*]}"
  create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
    "redis-values.yaml" \
    "redis-values.yaml" \
    "$REDIS_ARGS_STRING"
fi

# Apply proven Redis probe fixes after Helm deployment
echo "🔧 Apply Redis probe fixes..."
if apply_redis_probe_fixes "$redis_node_name" "$OC_PROJECT" "remove"; then
  echo "✅ All Redis probes removed successfully (matching test environment)"
else
  echo "⚠️ Redis probe fixes failed, but continuing..."
fi

# Scale to desired replicas
scale_deployment "statefulset" "$redis_node_name" "$REDIS_REPLICAS" "$REDIS_REPLICAS"

# Debug: Check actual probe configuration after fixes
echo "🔍 Debug: Verifying probe configuration after fixes..."
echo "Startup probes (should be empty/null):"
oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[0].startupProbe}' || echo "  Redis: No startup probe ✅"
oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[1].startupProbe}' || echo "  Sentinel: No startup probe ✅"
echo "Liveness probe delays (should be 180s):"
echo "  Redis: $(oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}')s"
echo "  Sentinel: $(oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[1].livenessProbe.initialDelaySeconds}')s"

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
if ! wait_for_redis_sync "$redis_node_name" 60 10 "$REDIS_REPLICAS"; then
  echo "Redis nodes failed to sync. Exiting..."
  exit 1
fi

# Phase 1: Generate initial Redis proxy config for minimal setup (1 pod)
echo "🔧 Phase 1: Generating initial Redis proxy configuration for namespace: $OC_PROJECT"
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
  echo "❌ Failed to generate initial Redis proxy configuration. Exiting..."
  exit 1
fi

# Validate the generated configuration
echo "🔍 Validating initial Redis proxy configuration..."
if ! validate_redis_proxy_config "$dynamic_config_file" "$OC_PROJECT" "$REDIS_NAME-node"; then
  echo "❌ Initial Redis proxy configuration failed validation. Exiting..."
  exit 1
fi

# Create the ConfigMap with the validated dynamic config
echo "✅ Creating ConfigMap with initial Redis proxy configuration..."
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
