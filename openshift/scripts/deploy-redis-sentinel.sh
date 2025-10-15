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

# Generate dynamic sentinel config for the current environment
generate_sentinel_config_json "$OC_PROJECT" "$REDIS_NAME-node" "redis-headless" 26379 "./config/redis/sentinel_tunnel.remote.config.json"

# Create the ConfigMap for Redis proxy with the generated config
create_or_update_configmap "$REDIS_PROXY_NAME-config" \
  "config.json=./config/redis/sentinel_tunnel.remote.config.json"

# Create a temporary values file
cat <<EOF > install.yaml
# Redis architecture configuration
architecture: replication
global:
  redis:
    password: ""
    extraEnvVars:
      - name: REDIS_PORT
        value: "6379"
redis:
  master:
    # Disable service links to prevent environment variable injection issues
    enableServiceLinks: false
    # Increase probe timeouts for better reliability
    livenessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 5
    readinessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 5
      failureThreshold: 5
    # Fix startup probe by removing problematic -ec flag and properly quoting the script call
    startupProbe:
      enabled: true
      exec:
        command:
          - /bin/bash
          - -c
          - '/health/ping_liveness_local.sh 5'
      initialDelaySeconds: 180
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 30
  replica:
    # Disable service links to prevent environment variable injection issues
    enableServiceLinks: false
    # Increase probe timeouts for better reliability
    livenessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 5
    readinessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 5
      failureThreshold: 5
    # Fix startup probe by removing problematic -ec flag and properly quoting the script call
    startupProbe:
      enabled: true
      exec:
        command:
          - /bin/bash
          - -c
          - '/health/ping_liveness_local.sh 5'
      initialDelaySeconds: 180
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 30
resources:
  requests:
    cpu: $REDIS_REQUEST_CPU
    memory: $REDIS_REQUEST_MEMORY
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
sentinel:
  enabled: true
  persistence:
    enabled: false
    size: 5Mi
  # Override environment variables that might be injected by services - Sentinel specific
  extraEnvVars:
    - name: REDIS_SENTINEL_PORT
      value: "26379"
  # Increase probe timeouts for better reliability
  livenessProbe:
    enabled: true
    timeoutSeconds: 10
    periodSeconds: 10
    failureThreshold: 5
  readinessProbe:
    enabled: true
    timeoutSeconds: 10
    periodSeconds: 5
    failureThreshold: 5
  # Fix startup probe by removing problematic -ec flag and properly quoting the script call
  startupProbe:
    enabled: true
    exec:
      command:
        - /bin/bash
        - -c
        - '/health/ping_sentinel.sh 5'
    initialDelaySeconds: 180
    timeoutSeconds: 10
    periodSeconds: 10
    failureThreshold: 30
  resources:
    requests:
      cpu: $REDIS_REQUEST_CPU
      memory: $REDIS_REQUEST_MEMORY
auth:
  enabled: false
  sentinel: false
  password: ""
  usePasswordFileFromSecret: false
EOF

# Create minimal file for updates (or it will fail)
cat <<EOF > upgrade.yaml
# Redis architecture configuration
architecture: replication
persistence:
  enabled: false
  storageClass: "-"
  storageClassName: "-"
  size: 0Mi
redis:
  master:
    # Disable service links to prevent environment variable injection issues
    enableServiceLinks: false
    # Increase probe timeouts for better reliability
    livenessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 5
    readinessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 5
      failureThreshold: 5
    # Fix startup probe by removing problematic -ec flag and properly quoting the script call
    startupProbe:
      enabled: true
      exec:
        command:
          - /bin/bash
          - -c
          - '/health/ping_liveness_local.sh 5'
      initialDelaySeconds: 180
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 30
  replica:
    # Disable service links to prevent environment variable injection issues
    enableServiceLinks: false
    # Increase probe timeouts for better reliability
    livenessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 5
    readinessProbe:
      enabled: true
      timeoutSeconds: 10
      periodSeconds: 5
      failureThreshold: 5
    # Fix startup probe by removing problematic -ec flag and properly quoting the script call
    startupProbe:
      enabled: true
      exec:
        command:
          - /bin/bash
          - -c
          - '/health/ping_liveness_local.sh 5'
      initialDelaySeconds: 180
      timeoutSeconds: 10
      periodSeconds: 10
      failureThreshold: 30
  persistence:
    enabled: false
    storageClass: "-"
    storageClassName: "-"
    size: 0Mi
  # Override environment variables that might be injected by services - Redis specific
  extraEnvVars:
    - name: REDIS_PORT
      value: "6379"
  resources:
    requests:
      memory: $REDIS_REQUEST_MEMORY
      cpu: $REDIS_REQUEST_CPU
    limits:
      memory: $REDIS_REQUEST_MEMORY
      cpu: $REDIS_REQUEST_CPU
replicas:
  replicaCount: $REDIS_REPLICAS
  persistence:
    enabled: false
  resources:
    requests:
      memory: $REDIS_REQUEST_MEMORY
      cpu: $REDIS_REQUEST_CPU
    limits:
      memory: $REDIS_REQUEST_MEMORY
      cpu: $REDIS_REQUEST_CPU
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
  # Override environment variables that might be injected by services - Sentinel specific
  extraEnvVars:
    - name: REDIS_SENTINEL_PORT
      value: "26379"
  # Increase probe timeouts for better reliability
  livenessProbe:
    enabled: true
    timeoutSeconds: 10
    periodSeconds: 10
    failureThreshold: 5
  readinessProbe:
    enabled: true
    timeoutSeconds: 10
    periodSeconds: 5
    failureThreshold: 5
  # Fix startup probe by removing problematic -ec flag and properly quoting the script call
  startupProbe:
    enabled: true
    exec:
      command:
        - /bin/bash
        - -c
        - '/health/ping_sentinel.sh 5'
    initialDelaySeconds: 180
    timeoutSeconds: 10
    periodSeconds: 10
    failureThreshold: 30
  resources:
    requests:
      memory: 32Mi
      cpu: 5m
    limits:
      memory: 256Mi
      cpu: 25m
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

# Define Redis-specific legacy image overrides
REDIS_LEGACY_ARGS="--set image.repository=bitnamilegacy/redis --set sentinel.image.repository=bitnamilegacy/redis-sentinel --set global.security.allowInsecureImages=true"

create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
  "install.yaml" \
  "upgrade.yaml" \
  "$REDIS_LEGACY_ARGS"
if ! wait_for "statefulset/$redis_node_name"; then
  echo "Failed to deploy Redis. Exiting..."
  exit 1
fi

# Fix: Remove the problematic master startup probe that Bitnami chart ignores in configuration
echo "🔧 Applying post-deployment fix: Removing problematic Redis master startup probe..."
remove_redis_master_startup_probe() {
  local statefulset_name="$1"

  echo "Checking if Redis master startup probe exists and needs removal..."

  # Check if startup probe exists on the redis container (first container)
  local has_startup_probe
  has_startup_probe=$(oc get statefulset "$statefulset_name" -o jsonpath='{.spec.template.spec.containers[0].startupProbe}' 2>/dev/null)

  if [[ -n "$has_startup_probe" && "$has_startup_probe" != "null" ]]; then
    echo "⚠️  Found problematic startup probe on Redis master container. Removing..."

    # Create a patch to remove the startup probe from the redis container
    cat > /tmp/remove-startup-probe-patch.json << 'EOF'
[
  {
    "op": "remove",
    "path": "/spec/template/spec/containers/0/startupProbe"
  }
]
EOF

    # Apply the patch to remove the startup probe
    if oc patch statefulset "$statefulset_name" --type=json --patch-file=/tmp/remove-startup-probe-patch.json; then
      echo "✅ Successfully removed Redis master startup probe"

      # Wait a moment for the change to be applied
      sleep 2

      # Verify the probe was removed
      local probe_check
      probe_check=$(oc get statefulset "$statefulset_name" -o jsonpath='{.spec.template.spec.containers[0].startupProbe}' 2>/dev/null)
      if [[ -z "$probe_check" || "$probe_check" == "null" ]]; then
        echo "✅ Verified: Redis master startup probe successfully removed"
      else
        echo "⚠️  Warning: Startup probe removal verification failed, but continuing deployment"
      fi

      # Clean up the temporary patch file
      rm -f /tmp/remove-startup-probe-patch.json
    else
      echo "⚠️  Warning: Failed to remove startup probe, but continuing deployment"
      rm -f /tmp/remove-startup-probe-patch.json
    fi
  else
    echo "✅ No problematic startup probe found on Redis master container"
  fi
}

# Apply the startup probe fix
remove_redis_master_startup_probe "$redis_node_name"

scale_deployment "statefulset" "$redis_node_name" "$REDIS_REPLICAS" "$REDIS_REPLICAS"

# Create a service for each redis pod
create_redis_services "$REDIS_NAME"

# Wait for Redis nodes to sync
if ! wait_for_redis_sync "$redis_node_name" "$OC_PROJECT" 60 10; then
  echo "Redis nodes failed to sync. Exiting..."
  exit 1
fi

# Temporary fix: swap 'e66ac2' with '950003' in the image tag for redis-proxy to fix a permissions issue with 950003 version
# DEPLOY_IMAGE_FIXED=$(echo "$REDIS_PROXY_IMAGE" | sed 's/:e66ac2-dev/:950003-dev/')
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
