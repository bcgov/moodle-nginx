#!/bin/bash

# Redis Utilities Module
# Contains Redis-specific operations, proxy configuration, and monitoring functions

# =============================================================================
# REDIS SERVICE MANAGEMENT
# =============================================================================

# Function to create Redis services for each pod
create_redis_services() {
  local redis_name=$1

  echo "Deploy Redis Service for each pod ..."
  PODS=$(oc get pods -l app.kubernetes.io/name=$redis_name -o jsonpath='{.items[*].metadata.name}')
  for pod_name in $PODS; do
    sed "s/\${POD_NAME}/$pod_name/g" < ./openshift/redis-services.yml | oc apply -f -
    echo "Service created for: $pod_name"
  done
}

# Function to wait for Redis synchronization
wait_for_redis_sync() {
  local redis_name=$1
  local max_retries=${2:-30}
  local wait_time=${3:-10}
  local expected_pods=${4:-5}

  echo "Waiting for Redis sync for: $redis_name (expected pods: $expected_pods)"

  local retry_count=0
  while [[ $retry_count -lt $max_retries ]]; do
    # Get running Redis pods using the proper utility function
    local running_pods=$(get_pods_for_resource "statefulset/$redis_name" "$DEPLOY_NAMESPACE" | tr ' ' '\n' | while read pod; do
      if [[ -n "$pod" ]]; then
        local phase=$(oc get pod "$pod" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
        if [[ "$phase" == "Running" ]]; then
          echo "$pod"
        fi
      fi
    done)
    local pod_count=$(echo "$running_pods" | grep -v '^$' | wc -l)

    if [[ $pod_count -eq $expected_pods ]]; then
      echo "✅ All $expected_pods Redis pods are running and synced"
      return 0
    else
      echo "Redis sync status: $pod_count/$expected_pods pods running (retry $retry_count/$max_retries)"
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "⚠️ Timeout: Only $pod_count/$expected_pods Redis pods are running after $((max_retries * wait_time)) seconds"
      return 1
    fi

    sleep $wait_time
  done
}

# Function to test Redis proxy connectivity
test_redis_proxy_connectivity() {
  local proxy_service="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local max_retries="${3:-10}"
  local wait_time="${4:-5}"

  echo "Testing Redis proxy connectivity: $proxy_service"

  local retry_count=0
  while [[ $retry_count -lt $max_retries ]]; do
    # Test Redis connectivity through the proxy
    local test_result=$(oc exec -n "$namespace" deployment/web -- redis-cli -h "$proxy_service" ping 2>/dev/null || echo "FAILED")

    if [[ "$test_result" == "PONG" ]]; then
      echo "✅ Redis proxy connectivity test successful"
      return 0
    else
      echo "Redis proxy connectivity test failed (retry $retry_count/$max_retries): $test_result"
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Redis proxy connectivity test failed after $max_retries attempts"
      return 1
    fi

    sleep $wait_time
  done
}

# Function to wait for Redis proxy to be ready
wait_for_redis_proxy_ready() {
  local proxy_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local max_retries="${3:-30}"
  local wait_time="${4:-10}"

  echo "Waiting for Redis proxy to be ready: $proxy_name"

  local retry_count=0
  while [[ $retry_count -lt $max_retries ]]; do
    # Check if Redis proxy pod is running
    local proxy_pod=$(oc get pods -l app=$proxy_name --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$proxy_pod" ]]; then
      # Test connectivity through the proxy
      if test_redis_proxy_connectivity "$proxy_name" "$namespace" 3 2; then
        echo "✅ Redis proxy $proxy_name is ready and responding"
        return 0
      else
        echo "Redis proxy pod is running but not responding (retry $retry_count/$max_retries)"
      fi
    else
      echo "Redis proxy pod not ready (retry $retry_count/$max_retries)"
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "⚠️ Timeout: Redis proxy $proxy_name not ready after $((max_retries * wait_time)) seconds"
      return 1
    fi

    sleep $wait_time
  done
}

# =============================================================================
# REDIS PROXY CONFIGURATION
# =============================================================================

# Function to generate Redis proxy configuration JSON
generate_redis_proxy_config_json() {
  local redis_name=$1
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local output_file="${3:-/tmp/redis-proxy-config.json}"

  echo "Generating Redis proxy configuration for: $redis_name"

  # Get Redis pods
  local redis_pods=$(oc get pods -l app.kubernetes.io/name=$redis_name -n "$namespace" -o jsonpath='{.items[*].metadata.name}')

  if [[ -z "$redis_pods" ]]; then
    echo "❌ No Redis pods found for: $redis_name"
    return 1
  fi

  # Build JSON configuration
  local config_json='{"clusters": [{"name": "redis-cluster", "servers": ['

  local first=true
  for pod in $redis_pods; do
    if [[ "$first" != "true" ]]; then
      config_json+=','
    fi
    config_json+="{\"host\": \"$pod\", \"port\": 6379}"
    first=false
  done

  config_json+=']}]}'

  # Write to output file
  echo "$config_json" > "$output_file"
  echo "✅ Redis proxy configuration written to: $output_file"
  return 0
}

# Function to validate Redis proxy configuration
validate_redis_proxy_config() {
  local config_file="$1"
  local expected_pod_count="${2:-5}"

  echo "Validating Redis proxy configuration: $config_file"

  if [[ ! -f "$config_file" ]]; then
    echo "❌ Configuration file not found: $config_file"
    return 1
  fi

  # Check if JSON is valid
  if ! jq empty "$config_file" 2>/dev/null; then
    echo "❌ Invalid JSON in configuration file"
    return 1
  fi

  # Check cluster configuration
  local server_count=$(jq '.clusters[0].servers | length' "$config_file" 2>/dev/null)

  if [[ "$server_count" != "$expected_pod_count" ]]; then
    echo "❌ Expected $expected_pod_count servers, found $server_count"
    return 1
  fi

  echo "✅ Redis proxy configuration is valid ($server_count servers configured)"
  return 0
}

# Function to check Redis proxy configuration status
check_redis_proxy_config() {
  local proxy_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_backends="${3:-5}"

  echo "Checking Redis proxy configuration status: $proxy_name"

  # Get proxy pod
  local proxy_pod=$(oc get pods -l app=$proxy_name --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  if [[ -z "$proxy_pod" ]]; then
    echo "❌ Redis proxy pod not found or not running"
    return 1
  fi

  # Check proxy configuration (implementation depends on proxy type)
  echo "✅ Redis proxy $proxy_name is running with pod: $proxy_pod"
  return 0
}

# =============================================================================
# REDIS PROBE MANAGEMENT
# =============================================================================

# Function to remove Redis startup probe
remove_redis_startup_probe() {
  local resource_type="$1"  # "statefulset" or "deployment"
  local resource_name="$2"
  local container_name="${3:-redis}"
  local namespace="${4:-$DEPLOY_NAMESPACE}"

  echo "🔧 Removing startup probe from $resource_type/$resource_name container '$container_name'..."

  # Create patch to remove startup probe
  local patch_ops='[{"op": "remove", "path": "/spec/template/spec/containers/0/startupProbe"}]'

  # Find the container index
  local container_index=$(oc get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.spec.template.spec.containers[*].name}' | tr ' ' '\n' | grep -n "^$container_name$" | cut -d: -f1)
  if [[ -n "$container_index" ]]; then
    container_index=$((container_index - 1))  # Convert to 0-based index
    patch_ops='[{"op": "remove", "path": "/spec/template/spec/containers/'$container_index'/startupProbe"}]'
  fi

  if apply_resource_patch "$resource_type" "$resource_name" "$patch_ops" "$namespace" "Removing startup probe"; then
    echo "✅ Startup probe removed from $resource_type/$resource_name"
    return 0
  else
    echo "⚠️ Failed to remove startup probe (may not exist)"
    return 1
  fi
}

# Function to fix container probes for Redis
fix_container_probes() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  echo "🔧 Fixing container probes for $resource_type/$resource_name..."

  # Remove problematic startup probes
  remove_redis_startup_probe "$resource_type" "$resource_name" "redis" "$namespace"
  remove_redis_startup_probe "$resource_type" "$resource_name" "sentinel" "$namespace"

  echo "✅ Container probe fixes applied to $resource_type/$resource_name"
}

# Function to fix Redis container probes specifically
fix_redis_container_probes() {
  local redis_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  echo "🔧 Fixing Redis container probes for: $redis_name"
  fix_container_probes "statefulset" "$redis_name" "$namespace"
}

# Function to fix Sentinel container probes specifically
fix_sentinel_container_probes() {
  local sentinel_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  echo "🔧 Fixing Sentinel container probes for: $sentinel_name"
  fix_container_probes "statefulset" "$sentinel_name" "$namespace"
}

# Function to remove all Redis probes
remove_all_redis_probes() {
  local redis_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  echo "🔧 Removing all probes from Redis StatefulSet: $redis_name"

  # Create comprehensive patch to remove all probes
  local patch_ops='[
    {"op": "remove", "path": "/spec/template/spec/containers/0/startupProbe"},
    {"op": "remove", "path": "/spec/template/spec/containers/0/livenessProbe"},
    {"op": "remove", "path": "/spec/template/spec/containers/0/readinessProbe"}
  ]'

  # Apply the patch (some operations may fail if probes don't exist)
  if apply_resource_patch "statefulset" "$redis_name" "$patch_ops" "$namespace" "Removing all Redis probes"; then
    echo "✅ All probes removed from Redis StatefulSet: $redis_name"
  else
    echo "⚠️ Some probe removals failed (probes may not exist)"
  fi

  # Also try to remove from sentinel container if it exists
  local sentinel_patch='[
    {"op": "remove", "path": "/spec/template/spec/containers/1/startupProbe"},
    {"op": "remove", "path": "/spec/template/spec/containers/1/livenessProbe"},
    {"op": "remove", "path": "/spec/template/spec/containers/1/readinessProbe"}
  ]'

  apply_resource_patch "statefulset" "$redis_name" "$sentinel_patch" "$namespace" "Removing Sentinel probes" || true
}

# Function to apply Redis probe fixes
apply_redis_probe_fixes() {
  local redis_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local fix_type="${3:-all}"  # "all", "redis", "sentinel", or "remove"

  echo "🔧 Applying Redis probe fixes: $fix_type for $redis_name"

  case "$fix_type" in
    "all")
      fix_redis_container_probes "$redis_name" "$namespace"
      fix_sentinel_container_probes "$redis_name" "$namespace"
      ;;
    "redis")
      fix_redis_container_probes "$redis_name" "$namespace"
      ;;
    "sentinel")
      fix_sentinel_container_probes "$redis_name" "$namespace"
      ;;
    "remove")
      remove_all_redis_probes "$redis_name" "$namespace"
      ;;
    *)
      echo "❌ Unknown fix type: $fix_type. Use: all, redis, sentinel, or remove"
      return 1
      ;;
  esac

  echo "✅ Redis probe fixes completed for: $redis_name"
}

# =============================================================================
# REDIS SCALING AND UPDATES
# =============================================================================

# Function to update Redis proxy after scaling
update_redis_proxy_after_scaling() {
  local redis_name="$1"
  local proxy_name="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  echo "🔄 Updating Redis proxy configuration after scaling..."

  # Generate new proxy configuration
  local config_file="/tmp/redis-proxy-config-update.json"
  if generate_redis_proxy_config_json "$redis_name" "$namespace" "$config_file"; then
    # Validate the new configuration
    if validate_redis_proxy_config "$config_file"; then
      echo "✅ Redis proxy configuration updated for scaling"

      # Restart proxy to pick up new configuration (if needed)
      if oc get deployment "$proxy_name" -n "$namespace" &> /dev/null; then
        echo "🔄 Restarting Redis proxy to pick up new configuration..."
        oc rollout restart deployment/"$proxy_name" -n "$namespace"
        oc rollout status deployment/"$proxy_name" -n "$namespace" --timeout=300s
      fi

      return 0
    else
      echo "❌ Generated proxy configuration is invalid"
      return 1
    fi
  else
    echo "❌ Failed to generate proxy configuration"
    return 1
  fi
}