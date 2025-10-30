#!/bin/bash
#set -e # Exit on error

# Source the utility script
source ./openshift/scripts/_utils.sh

# Load environment variables from versions file
if [[ -f "./example.versions.env" ]]; then
    source ./example.versions.env
else
    log_warn "example.versions.env not found - using environment variables from deployment"
fi

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

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
REDIS_CHART_VERSION="${REDIS_CHART_VERSION:-23.1.3}"

# Configure Redis deployment arguments
REDIS_ARGS=(
  "--set" "image.repository=$(echo "$REDIS_IMAGE" | cut -d':' -f1)"
  "--set" "image.tag=$(echo "$REDIS_IMAGE" | cut -d':' -f2)"
  "--set" "sentinel.image.repository=$(echo "$REDIS_SENTINEL_IMAGE" | cut -d':' -f1)"
  "--set" "sentinel.image.tag=$(echo "$REDIS_SENTINEL_IMAGE" | cut -d':' -f2)"
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
  imagePullSecrets:
    - name: "${ARTIFACTORY_PULL_SECRET:-artifactory-m950-learning}"

# Use proven working image tags from test environment
image:
  repository: $(echo "$REDIS_IMAGE" | cut -d':' -f1)
  tag: $(echo "$REDIS_IMAGE" | cut -d':' -f2)
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
    repository: $(echo "$REDIS_SENTINEL_IMAGE" | cut -d':' -f1)
    tag: $(echo "$REDIS_SENTINEL_IMAGE" | cut -d':' -f2)
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

  log_debug "Current images:"
  log_debug "  Redis: $current_redis_image"
  log_debug "  Sentinel: $current_sentinel_image"

  target_redis_image="$REDIS_IMAGE"
  target_sentinel_image="$REDIS_SENTINEL_IMAGE"

  log_debug "Target images:"
  log_debug "  Redis: $target_redis_image"
  log_debug "  Sentinel: $target_sentinel_image"

  # Check if changes require Helm reinstall (images or persistence settings)
  if [[ "$current_redis_image" != *"$target_redis_image"* ]] || [[ "$current_sentinel_image" != *"$target_sentinel_image"* ]]; then
    log_info "Decision: Image tags have changed - Redis match: $([[ "$current_redis_image" == *"$target_redis_image"* ]] && echo "YES" || echo "NO"), Sentinel match: $([[ "$current_sentinel_image" == *"$target_sentinel_image"* ]] && echo "YES" || echo "NO")"
    log_info "Image tags have changed. Helm reinstall required to handle StatefulSet recreation..."
    log_info "Scaling down existing StatefulSet before Helm uninstall..."

    scale_deployment "statefulset" "$redis_node_name" "0" "0"
    if ! wait_for "statefulset/$redis_node_name" "ready" "120s" "down"; then
      log_error "Failed to scale $redis_node_name to 0 replicas. Exiting..."
      exit 1
    fi

    # Use Helm to uninstall and reinstall to properly handle StatefulSet changes
    log_info "Uninstalling Helm release to allow clean recreation..."
    helm uninstall "$REDIS_NAME" || echo "Helm release may not exist, continuing..."

    # Wait for cleanup
    log_info "Waiting for resources to be cleaned up..."
    sleep 10

    # Set flag to force install instead of upgrade
    FORCE_HELM_INSTALL=true
  else
    # Check if the current StatefulSet is actually using persistent volume claims
    log_debug "Checking for existing Redis PVCs..."
    existing_redis_pvcs=$(oc get pvc -l app.kubernetes.io/name=redis -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    log_debug "Found Redis PVCs: '${existing_redis_pvcs}' (empty means none found)"

    if [[ -n "$existing_redis_pvcs" ]]; then
      log_warn "Old Redis PVCs detected: $existing_redis_pvcs"
      log_info "Checking if they're actually in use by current StatefulSet..."

      # Get PVCs that are actually bound to the current StatefulSet
      active_pvcs=$(oc get statefulset "$redis_node_name" -o jsonpath='{.spec.volumeClaimTemplates[*].metadata.name}' 2>/dev/null || echo "")
      log_debug "StatefulSet volume claim templates: '${active_pvcs}'"
      bound_pvcs=""

      if [[ -n "$active_pvcs" ]]; then
        # Check if any PVCs are actually bound to the StatefulSet
        for template in $active_pvcs; do
          pvc_pattern="${template}-${redis_node_name}-"
          log_debug "Checking for PVCs matching pattern: $pvc_pattern"
          if echo "$existing_redis_pvcs" | grep -q "$pvc_pattern"; then
            bound_pvcs="$bound_pvcs $pvc_pattern"
            log_debug "Found bound PVC pattern: $pvc_pattern"
          fi
        done
      fi

      if [[ -n "$bound_pvcs" ]]; then
        log_info "Current StatefulSet is using PVCs: $bound_pvcs"
        log_info "Helm reinstall required to disable persistence..."
        log_info "Scaling down existing StatefulSet before Helm uninstall..."

        scale_deployment "statefulset" "$redis_node_name" "0" "0"
        if ! wait_for "statefulset/$redis_node_name" "ready" "120s" "down"; then
          log_error "Failed to scale $redis_node_name to 0 replicas. Exiting..."
          exit 1
        fi

        # Use Helm to uninstall and reinstall to properly handle StatefulSet changes
        log_info "Uninstalling Helm release to allow clean recreation..."
        helm uninstall "$REDIS_NAME" || echo "Helm release may not exist, continuing..."

        # Wait for cleanup
        log_info "Waiting for resources to be cleaned up..."
        sleep 10

        # Set flag to force install instead of upgrade
        FORCE_HELM_INSTALL=true
      else
        log_info "Old PVCs found but not bound to current StatefulSet. Cleaning them up..."
        log_debug "PVCs to delete: $existing_redis_pvcs"
        # Delete unused PVCs safely
        for pvc in $existing_redis_pvcs; do
          log_info "Deleting unused PVC: $pvc"
          if oc delete pvc "$pvc"; then
            log_debug "Successfully deleted PVC: $pvc"
          else
            log_error "Failed to delete PVC $pvc, continuing..."
          fi
        done
        log_info "Performing standard scaling (no Helm reinstall needed)..."
        scale_deployment "statefulset" "$redis_node_name" "0" "0"
        if ! wait_for "statefulset/$redis_node_name" "ready" "120s" "down"; then
          log_error "Failed to scale $redis_node_name to 0 replicas. Exiting..."
          exit 1
        fi
      fi
    else
      log_debug "No Redis PVCs found. Performing standard scaling..."
      scale_deployment "statefulset" "$redis_node_name" "0" "0"
      if ! wait_for "statefulset/$redis_node_name" "ready" "120s" "down"; then
        log_error "Failed to scale $redis_node_name to 0 replicas. Exiting..."
        exit 1
      fi
    fi
  fi
fi

# Create or update the Helm deployment
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

log_debug "Redis Helm chart information:"
if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
  helm search repo bitnami/redis --versions | head -5
fi

log_info "🔧 Using Redis chart version: $REDIS_CHART_VERSION"

log_debug "Checking generated redis-values.yaml file..."
log_debug "--- FIPS Configuration ---"
if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
  grep -A 5 -B 5 "Fips\|fips" redis-values.yaml || echo "No FIPS configuration found in values file"
fi
log_debug "--- End FIPS Configuration ---"

log_debug "Redis deployment info:"
log_debug "  Redis: bitnamilegacy/redis:8.0.2-debian-12-r2"
log_debug "  Sentinel: bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1"
log_debug "Chart: $REDIS_CHART_VERSION"

log_debug "Helm deployment arguments:"
if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
  printf '%s\n' "${REDIS_ARGS[@]}"
fi

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
  log_info "🔧 Performing standard Helm upgrade..."
  # Convert array to string for create_or_update_helm_deployment
  REDIS_ARGS_STRING="${REDIS_ARGS[*]}"
  create_or_update_helm_deployment "$REDIS_NAME" "$REDIS_HELM_CHART" \
    "redis-values.yaml" \
    "redis-values.yaml" \
    "$REDIS_ARGS_STRING"
fi

# Apply proven Redis probe fixes after Helm deployment
log_info "🔧 Apply Redis probe fixes..."
if apply_redis_probe_fixes "$redis_node_name" "$OC_PROJECT" "remove"; then
  log_info "✅ All Redis probes removed successfully (matching test environment)"
else
  log_warn "⚠️ Redis probe fixes failed, but continuing..."
fi

# Scale to desired replicas
scale_deployment "statefulset" "$redis_node_name" "$REDIS_REPLICAS" "$REDIS_REPLICAS"

# Debug: Check actual probe configuration after fixes
log_debug "🔍 Debug: Verifying probe configuration after fixes..."
log_debug "Startup probes (should be empty/null):"
oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[0].startupProbe}' || echo "  Redis: No startup probe ✅"
oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[1].startupProbe}' || echo "  Sentinel: No startup probe ✅"
log_debug "Liveness probe delays (should be 180s):"
log_debug "  Redis: $(oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.initialDelaySeconds}')s"
log_debug "  Sentinel: $(oc get statefulset/$redis_node_name -o jsonpath='{.spec.template.spec.containers[1].livenessProbe.initialDelaySeconds}')s"

# Now wait for the StatefulSet to be ready with the correct probe configurations
log_info "🔍 Monitoring Redis container startup..."

if ! wait_for "statefulset/$redis_node_name"; then
  log_error "Failed to deploy Redis. Checking container status..."

  # Get pod status and logs for debugging
  pod_name="${redis_node_name}-0"
  log_debug "🔍 Debug: Pod status for $pod_name:"
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    oc describe pod "$pod_name" | grep -A 10 -B 10 "State\|Conditions\|Events"
  fi

  log_debug "🔍 Debug: Recent Redis container logs:"
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    oc logs "$pod_name" -c redis --tail=20 || echo "Cannot get Redis logs"
  fi

  log_debug "🔍 Debug: Recent Sentinel container logs:"
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    oc logs "$pod_name" -c sentinel --tail=20 || echo "Cannot get Sentinel logs"
  fi

  exit 1
fi

# Create a service for each redis pod
create_redis_services "$REDIS_NAME"

# Wait for Redis nodes to sync
if ! wait_for_redis_sync "$redis_node_name" 60 10 "$REDIS_REPLICAS"; then
  log_error "Redis nodes failed to sync. Exiting..."
  exit 1
fi

# Phase 1: Generate initial Redis proxy config for minimal setup (1 pod)
log_info "🔧 Phase 1: Generating initial Redis proxy configuration for namespace: $OC_PROJECT"
dynamic_config_file="/tmp/sentinel_tunnel.${OC_PROJECT}.config.json"

# Set up cleanup trap
cleanup_temp_config() {
  if [[ -f "$dynamic_config_file" ]]; then
    log_debug "🧹 Cleaning up temporary config file: $dynamic_config_file"
    rm -f "$dynamic_config_file"
  fi
}
trap cleanup_temp_config EXIT

if ! generate_redis_proxy_config_json "$REDIS_NAME-node" "$OC_PROJECT" "$dynamic_config_file"; then
  log_error "Failed to generate initial Redis proxy configuration. Exiting..."
  exit 1
fi

# Validate the generated configuration
log_info "🔍 Validating initial Redis proxy configuration..."
if ! validate_redis_proxy_config "$dynamic_config_file"; then
  log_error "Initial Redis proxy configuration failed validation. Exiting..."
  exit 1
fi

# Create the ConfigMap with the validated dynamic config
log_info "Creating ConfigMap with initial Redis proxy configuration..."
create_or_update_configmap "$REDIS_PROXY_NAME-config" \
  "config.json=$dynamic_config_file"

# Deploy the Redis proxy
deploy_resource_from_template ./openshift/redis-proxy.yml \
  DEPLOY_IMAGE=${REDIS_PROXY_IMAGE} \
  REDIS_PROXY_NAME=$REDIS_PROXY_NAME
if ! wait_for "deployment/$REDIS_PROXY_NAME"; then
  log_error "Failed to deploy Redis Proxy. Exiting..."
  exit 1
fi

# Deploy Redis Insight (removed due to security flags)
# log_info "Deploying Redis Insight..."
# oc apply -f ./openshift/redis-insight.yml

# Verify Redis Proxy is ready and functional
log_info "Waiting for Redis Proxy to be ready and functional..."
if ! wait_for_redis_proxy_ready "$REDIS_PROXY_NAME" "$OC_PROJECT" 60 10; then
  log_error "Redis Proxy failed to become ready and functional. Exiting..."
  exit 1
fi
log_info "Redis Proxy is fully functional."

# Verify Artifactory image pull secrets are configured
log_info "Verifying Artifactory access for Redis deployments..."
failed_count=0

if ensure_image_pull_secrets "statefulset" "$redis_node_name"; then
  log_info "✅ Redis StatefulSet has Artifactory access confirmed"
else
  log_warn "⚠️ Redis StatefulSet may have imagePullSecrets issues (this should have been configured during Helm deployment)"
  ((failed_count++))
fi

if ensure_image_pull_secrets "deployment" "$REDIS_PROXY_NAME"; then
  log_info "✅ Redis Proxy deployment has Artifactory access confirmed"
else
  log_warn "⚠️ Redis Proxy may have imagePullSecrets issues (this should have been configured during Helm deployment)"
  ((failed_count++))
fi

if [[ $failed_count -eq 0 ]]; then
  log_info "🎉 All Redis components have Artifactory access confirmed"
fi

log_success "Redis deployment completed successfully!"
