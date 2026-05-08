#!/bin/bash
# =============================================================================
# cluster-health.sh - Cluster Health & Event Monitoring
# =============================================================================
# PURPOSE:
#   Provides centralized cluster health monitoring with intelligent wait
#   functions that detect infrastructure issues (storage, node, network).
#
#   Automatically extends timeouts and provides troubleshooting visibility
#   when infrastructure problems are detected during deployments.
#
# CORE FUNCTIONS:
#   - check_cluster_health() - Detect PVC, CSI, node, and network issues
#   - show_cluster_events() - Display troubleshooting events
#   - wait_with_cluster_monitoring() - Enhanced wait with health checks
#   - wait_for_resource_ready() - Universal resource readiness check
#   - get_expected_replica_count() - Auto-detect replica counts
#   - check_resource_ready() - StatefulSet/Deployment readiness verification
#
# USAGE:
#   source ./openshift/scripts/utils/cluster-health.sh
#
#   # Check cluster health for a specific resource
#   health_status=$(check_cluster_health "deployment" "php" "$namespace")
#
#   # Wait with health monitoring
#   wait_with_cluster_monitoring "statefulset" "mariadb-galera" \
#     "my_wait_function" "$namespace" 3600
#
#   # Wait for resource to be ready (with cluster monitoring)
#   wait_for_resource_ready "app.kubernetes.io/name=mariadb-galera" \
#     "$namespace" 30 10 "MariaDB Galera"
#
# ENVIRONMENT VARIABLES:
#   CLUSTER_HEALTH_MONITORING - Enable centralized monitoring (default: YES)
#   DEPLOY_NAMESPACE - Target namespace (required)
#
# DEPENDENCIES:
#   - logging.sh (log_* functions)
#
# RELATED DOCS:
#   - docs/galera-deployment-best-practices.md
#   - docs/pod-health-monitor-coordination-strategy.md
# =============================================================================

# =============================================================================
# CLUSTER HEALTH DETECTION
# =============================================================================

# Function to check for critical cluster events that would prevent successful deployment
check_cluster_health() {
  local resource_type="$1"     # e.g., "pod", "deployment", "statefulset"
  local resource_name="$2"     # e.g., "mariadb-galera", "maintenance-message"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local check_duration="${4:-5m}"  # How far back to check events (5m, 10m, 1h)

  log_debug "🔍 Checking cluster health for $resource_type/$resource_name..."

  # Get recent events for the specific resource
  local events_output
  events_output=$(oc get events -n "$namespace" --field-selector involvedObject.name="$resource_name",involvedObject.kind="$resource_type" --sort-by='.lastTimestamp' -o json 2>/dev/null)

  if [[ -z "$events_output" || "$events_output" == '{"items":[]}' ]]; then
    # No specific events found, check for general cluster issues
    events_output=$(oc get events -n "$namespace" --sort-by='.lastTimestamp' -o json 2>/dev/null)
  fi

  # Parse events and look for critical issues
  local critical_issues=()
  local pvc_issues=0
  local csi_issues=0
  local node_issues=0
  local network_issues=0

  if [[ -n "$events_output" && "$events_output" != '{"items":[]}' ]]; then
    # Check for PVC/storage issues
    if echo "$events_output" | grep -qi "AttachVolume.Attach failed\|timed out waiting for external-attacher\|CSI driver.*attach.*failed\|volume.*attach.*failed"; then
      pvc_issues=$((pvc_issues + 1))
      critical_issues+=("PVC_ATTACH_FAILURES")
    fi

    # Check for CSI/storage driver issues
    if echo "$events_output" | grep -qi "csi.trident.netapp.io\|DeadlineExceeded.*attach\|context deadline exceeded.*volume"; then
      csi_issues=$((csi_issues + 1))
      critical_issues+=("CSI_DRIVER_ISSUES")
    fi

    # Check for node/scheduling issues
    if echo "$events_output" | grep -qi "FailedScheduling\|InsufficientMemory\|InsufficientCPU\|NodeNotReady"; then
      node_issues=$((node_issues + 1))
      critical_issues+=("NODE_SCHEDULING_ISSUES")
    fi

    # Check for network issues
    if echo "$events_output" | grep -qi "NetworkNotReady\|CNI.*failed\|network.*timeout"; then
      network_issues=$((network_issues + 1))
      critical_issues+=("NETWORK_ISSUES")
    fi
  fi

  # Determine severity and recommended action
  local total_issues=$((pvc_issues + csi_issues + node_issues + network_issues))

  if [[ $total_issues -gt 0 ]]; then
    log_warn "⚠️ Cluster health issues detected for $resource_type/$resource_name:"
    [[ $pvc_issues -gt 0 ]] && log_warn "  - PVC attachment failures: $pvc_issues"
    [[ $csi_issues -gt 0 ]] && log_warn "  - CSI driver issues: $csi_issues"
    [[ $node_issues -gt 0 ]] && log_warn "  - Node/scheduling issues: $node_issues"
    [[ $network_issues -gt 0 ]] && log_warn "  - Network issues: $network_issues"

    # Return the most severe issue type
    if [[ $pvc_issues -gt 0 || $csi_issues -gt 0 ]]; then
      echo "STORAGE_CRITICAL"
      return 2  # Critical storage issues
    elif [[ $node_issues -gt 0 ]]; then
      echo "NODE_CRITICAL"
      return 1  # Node issues
    elif [[ $network_issues -gt 0 ]]; then
      echo "NETWORK_WARNING"
      return 1  # Network issues
    fi
  else
    log_debug "✅ No critical cluster health issues detected"
    echo "HEALTHY"
    return 0
  fi
}

# Function to display detailed cluster events for troubleshooting
show_cluster_events() {
  local resource_type="$1"
  local resource_name="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  log_info "📋 Recent cluster events for $resource_type/$resource_name:"
  echo "----------------------------------------"

  # Show events for the specific resource
  local specific_events
  specific_events=$(oc get events -n "$namespace" --field-selector involvedObject.name="$resource_name" --sort-by='.lastTimestamp' --no-headers 2>/dev/null | tail -10)

  if [[ -n "$specific_events" ]]; then
    echo "🎯 Specific events for $resource_name:"
    echo "$specific_events"
    echo ""
  fi

  # Show general cluster events that might be relevant
  echo "🌐 General cluster events (last 10):"
  oc get events -n "$namespace" --sort-by='.lastTimestamp' --no-headers 2>/dev/null | grep -E "(Failed|Error|Warning)" | tail -10 | head -5
  echo "----------------------------------------"
}

# =============================================================================
# CENTRALIZED CLUSTER HEALTH MONITORING
# =============================================================================

# Function to wait with centralized cluster health monitoring
wait_with_cluster_monitoring() {
  local resource_type="$1"      # e.g., "deployment", "statefulset"
  local resource_name="$2"      # e.g., "mariadb-galera"
  local wait_function="$3"      # Function to call for actual waiting
  local namespace="${4:-$DEPLOY_NAMESPACE}"
  local max_wait_time="${5:-3600}"  # 60 minutes default

  # Centralized cluster monitoring configuration
  local cluster_monitoring_enabled="${CLUSTER_HEALTH_MONITORING:-YES}"
  local last_health_check=0
  local health_check_interval=300  # Check every 5 minutes
  local consecutive_storage_failures=0
  local max_storage_failures=3

  local elapsed_time=0

  # Show monitoring configuration
  if [[ "$cluster_monitoring_enabled" == "YES" ]]; then
    log_info "  Starting deployment wait with centralized cluster health monitoring..."
    log_info "  Resource: $resource_type/$resource_name"
    log_info "  Max wait time: ${max_wait_time}s"
    log_info "  Health check interval: ${health_check_interval}s"
    log_info "  CLUSTER_HEALTH_MONITORING: $cluster_monitoring_enabled"
  else
    log_info "  Starting deployment wait (cluster monitoring disabled)..."
    log_info "  Resource: $resource_type/$resource_name"
    log_info "  Max wait time: ${max_wait_time}s"
    log_info "  CLUSTER_HEALTH_MONITORING: $cluster_monitoring_enabled"
  fi

  while [[ $elapsed_time -lt $max_wait_time ]]; do
    # Run the actual wait function (non-blocking check)
    if $wait_function; then
      log_success "Resource deployment completed successfully!"
      return 0
    fi

    # Perform cluster health check if enabled
    if [[ "$cluster_monitoring_enabled" == "YES" ]]; then
      if [[ $((elapsed_time - last_health_check)) -ge $health_check_interval ]]; then
        log_debug "Performing centralized cluster health check for $resource_type/$resource_name..."

        local health_status
        health_status=$(check_cluster_health "$resource_type" "$resource_name" "$namespace")
        local health_exit_code=$?

        case "$health_status" in
          "STORAGE_CRITICAL")
            consecutive_storage_failures=$((consecutive_storage_failures + 1))
            log_warn "Storage issues detected while waiting for $resource_type/$resource_name (attempt $consecutive_storage_failures/$max_storage_failures)"

            if [[ $consecutive_storage_failures -ge $max_storage_failures ]]; then
              log_warn "Extending wait time due to persistent storage issues..."
              # Extend max_wait_time for storage issues
              max_wait_time=$((max_wait_time + 900))  # Add 15 minutes
              log_info "Showing cluster events for troubleshooting..."
              show_cluster_events "$resource_type" "$resource_name" "$namespace"
            fi
            ;;
          "NODE_CRITICAL"|"NETWORK_WARNING")
            log_warn "Cluster infrastructure issues detected while waiting for $resource_type/$resource_name"
            show_cluster_events "$resource_type" "$resource_name" "$namespace"
            ;;
          "HEALTHY")
            consecutive_storage_failures=0
            log_debug "Centralized cluster health check: Normal (waiting for $resource_type/$resource_name)"
            ;;
        esac

        last_health_check=$elapsed_time
      fi
    fi

    # Sleep and update elapsed time
    sleep 10
    elapsed_time=$((elapsed_time + 10))

    # Provide periodic status updates
    if [[ $((elapsed_time % 300)) -eq 0 ]]; then  # Every 5 minutes
      local minutes_elapsed=$((elapsed_time / 60))
      local minutes_remaining=$(((max_wait_time - elapsed_time) / 60))
      log_info "⏳ Still waiting... ${minutes_elapsed}m elapsed, ${minutes_remaining}m remaining"
    fi
  done

  log_error "Deployment wait timed out after ${max_wait_time} seconds"

  # Show final cluster health check on timeout if monitoring enabled
  if [[ "$cluster_monitoring_enabled" == "YES" ]]; then
    log_info "📋 Final centralized cluster health check..."
    show_cluster_events "$resource_type" "$resource_name" "$namespace"
  fi

  return 1
}

# =============================================================================
# RESOURCE READINESS UTILITIES
# =============================================================================

# Function to dynamically determine expected replica count from Kubernetes resource
get_expected_replica_count() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Extract resource name from selector (e.g., "app.kubernetes.io/name=mariadb-galera" -> "mariadb-galera")
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Check StatefulSet first (most common for databases)
  if oc get statefulset "$resource_name" -n "$namespace" &>/dev/null; then
    local replicas
    replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [[ -n "$replicas" && "$replicas" =~ ^[0-9]+$ && "$replicas" -gt 0 ]]; then
      echo "$replicas"
      return 0
    else
      echo "❌ Error: StatefulSet $resource_name exists but has invalid replica count: '$replicas'" >&2
      return 1
    fi
  fi

  # Check Deployment as fallback
  if oc get deployment "$resource_name" -n "$namespace" &>/dev/null; then
    local replicas
    replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    if [[ -n "$replicas" && "$replicas" =~ ^[0-9]+$ && "$replicas" -gt 0 ]]; then
      echo "$replicas"
      return 0
    else
      echo "❌ Error: Deployment $resource_name exists but has invalid replica count: '$replicas'" >&2
      return 1
    fi
  fi

  echo "❌ Error: No StatefulSet or Deployment found for resource name: $resource_name (from selector: $selector)" >&2
  return 1
}

# Get current replicas for a resource
get_replicas() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Determine resource type and get current replicas
  local original_replicas=""

  if oc get statefulset "$resource_name" -n "$namespace" &>/dev/null; then
    original_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}')
  elif oc get deployment "$resource_name" -n "$namespace" &>/dev/null; then
    original_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}')
  else
    echo "0"
    return 1
  fi

  echo "${original_replicas:-0}"
  return 0
}

# Function to check if StatefulSet/Deployment has all replicas available and ready
check_resource_ready() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Extract resource name from selector
  local resource_name
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
  else
    resource_name="$selector"
  fi

  # Check StatefulSet first
  if oc get statefulset "$resource_name" -n "$namespace" &>/dev/null; then
    local spec_replicas ready_replicas available_replicas
    spec_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    ready_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    available_replicas=$(oc get statefulset "$resource_name" -n "$namespace" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)

    if [[ -n "$spec_replicas" && "$spec_replicas" =~ ^[0-9]+$ &&
          -n "$ready_replicas" && "$ready_replicas" =~ ^[0-9]+$ &&
          -n "$available_replicas" && "$available_replicas" =~ ^[0-9]+$ ]]; then
      if [[ "$spec_replicas" -eq "$ready_replicas" && "$spec_replicas" -eq "$available_replicas" ]]; then
        echo "✅ StatefulSet $resource_name: $available_replicas/$spec_replicas replicas ready and available"
        return 0
      else
        echo "⏳ StatefulSet $resource_name: $ready_replicas/$spec_replicas ready, $available_replicas available"
        return 1
      fi
    else
      echo "⏳ StatefulSet $resource_name: waiting for status to be available..."
      return 1
    fi
  fi

  # Check Deployment as fallback
  if oc get deployment "$resource_name" -n "$namespace" &>/dev/null; then
    local spec_replicas ready_replicas available_replicas
    spec_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    ready_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    available_replicas=$(oc get deployment "$resource_name" -n "$namespace" -o jsonpath='{.status.availableReplicas}' 2>/dev/null)

    if [[ -n "$spec_replicas" && "$spec_replicas" =~ ^[0-9]+$ &&
          -n "$ready_replicas" && "$ready_replicas" =~ ^[0-9]+$ &&
          -n "$available_replicas" && "$available_replicas" =~ ^[0-9]+$ ]]; then
      if [[ "$spec_replicas" -eq "$ready_replicas" && "$spec_replicas" -eq "$available_replicas" ]]; then
        echo "✅ Deployment $resource_name: $available_replicas/$spec_replicas replicas ready and available"
        return 0
      else
        echo "⏳ Deployment $resource_name: $ready_replicas/$spec_replicas ready, $available_replicas available"
        return 1
      fi
    else
      echo "⏳ Deployment $resource_name: waiting for status to be available..."
      return 1
    fi
  fi

  echo "❌ Error: No StatefulSet or Deployment found for resource name: $resource_name (from selector: $selector)" >&2
  return 1
}

# Function to wait for resource to be ready with configurable timeout
wait_for_resource_ready() {
  local selector="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local max_retries="${3:-30}"
  local wait_time="${4:-10}"
  local description="${5:-resource}"

  echo "⏳ Waiting for $description to be ready (selector: $selector)..."

  # Extract resource type and name for cluster monitoring (if available)
  local resource_type=""
  local resource_name=""
  if [[ "$selector" =~ = ]]; then
    resource_name="${selector##*=}"
    # Try to determine resource type by checking what exists
    if oc get statefulset "$resource_name" -n "$namespace" &>/dev/null; then
      resource_type="statefulset"
    elif oc get deployment "$resource_name" -n "$namespace" &>/dev/null; then
      resource_type="deployment"
    fi
  fi

  # Use cluster health monitoring if enabled and resource type is available
  if [[ "${CLUSTER_HEALTH_MONITORING:-YES}" == "YES" && -n "$resource_type" ]]; then
    log_debug "🔄 Using centralized cluster health monitoring for $description ($resource_type/$resource_name)..."

    # Create a single-iteration wrapper function for the centralized monitoring
    eval "
    readiness_check_wrapper() {
      check_resource_ready \"$selector\" \"$namespace\"
      return \$?
    }
    "

    # Calculate timeout in seconds (max_retries * wait_time)
    local timeout_seconds=$((max_retries * wait_time))

    # Use centralized cluster health monitoring
    wait_with_cluster_monitoring "$resource_type" "$resource_name" "readiness_check_wrapper" "$namespace" "$timeout_seconds"
    local result=$?

    if [[ $result -eq 0 ]]; then
      echo "✅ $description is ready"
    else
      echo "⚠️ Timeout: $description did not become ready after $timeout_seconds seconds"
    fi

    return $result
  else
    log_debug "🔄 Using traditional waiting for $description (CLUSTER_HEALTH_MONITORING=${CLUSTER_HEALTH_MONITORING:-NO} or resource type unavailable)..."

    # Use traditional waiting without cluster monitoring
    local retries=0
    while [[ $retries -lt $max_retries ]]; do
      if check_resource_ready "$selector" "$namespace"; then
        echo "✅ $description is ready"
        return 0
      else
        echo "    $description not ready yet... (retry $retries/$max_retries)"
      fi

      retries=$((retries + 1))
      sleep "$wait_time"
    done

    echo "⚠️ Timeout: $description did not become ready after $((max_retries * wait_time)) seconds"
    return 1
  fi
}
