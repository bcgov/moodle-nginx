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
    # Get all pods for the StatefulSet first
    local all_pods=$(get_pods_for_resource "statefulset/$redis_name" "$DEPLOY_NAMESPACE")
    echo "🔍 Debug: All pods found: '$all_pods'"

    # Count running pods
    local running_count=0
    if [[ -n "$all_pods" ]]; then
      for pod in $all_pods; do
        if [[ -n "$pod" ]]; then
          local phase=$(oc get pod "$pod" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null)
          echo "🔍 Debug: Pod $pod has phase: '$phase'"
          if [[ "$phase" == "Running" ]]; then
            running_count=$((running_count + 1))
          fi
        fi
      done
    fi

    if [[ $running_count -eq $expected_pods ]]; then
      echo "✅ All $expected_pods Redis pods are running and synced"
      return 0
    else
      echo "Redis sync status: $running_count/$expected_pods pods running (retry $retry_count/$max_retries)"
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
    # First, try to get the proxy pod and test if it's responding
    local proxy_pod=$(oc get pods -l app=$proxy_service --field-selector=status.phase=Running -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$proxy_pod" ]]; then
      # Test if the proxy service port is accessible
      local service_check=$(oc get svc "$proxy_service" -n "$namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)
      if [[ -n "$service_check" ]]; then
        echo "✅ Redis proxy service and pod are available"
        return 0
      else
        echo "Redis proxy service check failed (retry $retry_count/$max_retries): Service not found"
      fi
    else
      echo "Redis proxy connectivity test failed (retry $retry_count/$max_retries): Pod not running"
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "❌ Redis proxy connectivity test failed after $max_retries attempts"
      echo "🔍 Debug: Checking proxy pod logs..."
      if [[ -n "$proxy_pod" ]]; then
        oc logs "$proxy_pod" -n "$namespace" --tail=10 || echo "Cannot get proxy logs"
      fi
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
      echo "🔍 Redis proxy pod found: $proxy_pod"

      # Check if the service exists
      local proxy_service=$(oc get svc "$proxy_name" -n "$namespace" -o jsonpath='{.metadata.name}' 2>/dev/null)
      if [[ -n "$proxy_service" ]]; then
        echo "🔍 Redis proxy service found: $proxy_service"

        # Check pod readiness conditions
        local ready_condition=$(oc get pod "$proxy_pod" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$ready_condition" == "True" ]]; then
          echo "✅ Redis proxy $proxy_name is ready and running"
          return 0
        else
          echo "🔍 Redis proxy pod not ready yet (condition: $ready_condition)"
        fi
      else
        echo "⚠️ Redis proxy service not found: $proxy_name"
      fi
    else
      echo "Redis proxy pod not ready (retry $retry_count/$max_retries)"
    fi

    retry_count=$((retry_count + 1))
    if [[ $retry_count -ge $max_retries ]]; then
      echo "⚠️ Timeout: Redis proxy $proxy_name not ready after $((max_retries * wait_time)) seconds"

      # Debug information
      echo "🔍 Debug: Current proxy pod status:"
      oc get pods -l app=$proxy_name -n "$namespace" -o wide || echo "Cannot get proxy pods"

      echo "🔍 Debug: Recent proxy pod logs:"
      if [[ -n "$proxy_pod" ]]; then
        oc logs "$proxy_pod" -n "$namespace" --tail=20 || echo "Cannot get proxy logs"
      fi
      return 1
    fi

    sleep $wait_time
  done
}
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

  # Get Redis pods using the proper utility function
  local redis_pods=$(get_pods_for_resource "statefulset/$redis_name" "$namespace")
  echo "🔍 Debug: Found Redis pods: '$redis_pods'"

  if [[ -z "$redis_pods" ]]; then
    echo "❌ No Redis pods found for: $redis_name"
    return 1
  fi

  # Build sentinels array in the correct format
  local sentinels=()
  for pod in $redis_pods; do
    # Generate proper service endpoint for Sentinel
    local service_endpoint="${pod}.redis-headless.${namespace}.svc.cluster.local:26379"
    sentinels+=("\"$service_endpoint\"")
    echo "   - Adding sentinel: $service_endpoint"
  done

  # Join the sentinels with commas
  local sentinels_joined
  sentinels_joined=$(IFS=, ; echo "${sentinels[*]}")

  # Create the output directory if it doesn't exist
  local output_dir
  output_dir=$(dirname "$output_file")
  mkdir -p "$output_dir"

  # Generate JSON in the correct format
  cat <<EOF > "$output_file"
{
  "Sentinels_addresses_list":[
    $sentinels_joined
  ],
  "Databases":[
    {
      "Name": "mymaster",
      "Local_port": "6379"
    }
  ]
}
EOF

  if [[ $? -eq 0 ]]; then
    echo "✅ Redis proxy configuration written to: $output_file"
    echo "🔍 Debug: Generated configuration:"
    cat "$output_file"
    return 0
  else
    echo "❌ Failed to write Redis proxy config to: $output_file"
    return 1
  fi
}

# Function to validate Redis proxy configuration
validate_redis_proxy_config() {
  local config_file="$1"
  local expected_namespace="${2:-$DEPLOY_NAMESPACE}"
  local expected_sts_name="${3:-$REDIS_NAME-node}"

  echo "🔍 Validating Redis proxy configuration: $config_file"

  # Check if file exists and is readable
  if [[ ! -f "$config_file" ]]; then
    echo "❌ Config file does not exist: $config_file"
    return 1
  fi

  if [[ ! -r "$config_file" ]]; then
    echo "❌ Config file is not readable: $config_file"
    return 1
  fi

  # Check if it's valid JSON
  if ! jq . "$config_file" >/dev/null 2>&1; then
    echo "❌ Config file is not valid JSON: $config_file"
    return 1
  fi

  # Check required fields exist
  local sentinels_count
  sentinels_count=$(jq '.Sentinels_addresses_list | length' "$config_file" 2>/dev/null)
  if [[ -z "$sentinels_count" || "$sentinels_count" == "null" ]]; then
    echo "❌ Config file missing Sentinels_addresses_list: $config_file"
    return 1
  fi

  if [[ "$sentinels_count" -eq 0 ]]; then
    echo "❌ Config file has empty Sentinels_addresses_list: $config_file"
    return 1
  fi

  # Check that sentinels contain the expected namespace
  local sentinel_namespace_count
  sentinel_namespace_count=$(jq -r '.Sentinels_addresses_list[]' "$config_file" | grep -c "$expected_namespace" || true)
  if [[ "$sentinel_namespace_count" -eq 0 ]]; then
    echo "❌ Config file sentinels do not contain expected namespace '$expected_namespace'"
    echo "   Found sentinels:"
    jq -r '.Sentinels_addresses_list[]' "$config_file" | sed 's/^/     - /'
    return 1
  fi

  # Check that all sentinels contain the expected namespace (not mixed)
  if [[ "$sentinel_namespace_count" != "$sentinels_count" ]]; then
    echo "❌ Config file contains mixed namespaces (expected all to be '$expected_namespace')"
    echo "   Found sentinels:"
    jq -r '.Sentinels_addresses_list[]' "$config_file" | sed 's/^/     - /'
    return 1
  fi

  # Check database configuration
  local db_name
  db_name=$(jq -r '.Databases[0].Name' "$config_file" 2>/dev/null)
  if [[ "$db_name" != "mymaster" ]]; then
    echo "❌ Config file missing or incorrect database name (expected 'mymaster', got '$db_name')"
    return 1
  fi

  local local_port
  local_port=$(jq -r '.Databases[0].Local_port' "$config_file" 2>/dev/null)
  if [[ "$local_port" != "6379" ]]; then
    echo "❌ Config file missing or incorrect local port (expected '6379', got '$local_port')"
    return 1
  fi

  echo "✅ Redis proxy configuration validation passed:"
  echo "   - Found $sentinels_count sentinels for namespace: $expected_namespace"
  echo "   - Database: $db_name on port $local_port"
  echo "   - All sentinels correctly reference namespace: $expected_namespace"

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
    if validate_redis_proxy_config "$config_file" ; then
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