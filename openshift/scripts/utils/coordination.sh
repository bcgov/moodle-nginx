#!/bin/bash
# =============================================================================
# coordination.sh - Pod-Health-Monitor Coordination & Deployment Orchestration
# =============================================================================
# PURPOSE:
#   Provides coordination layer between deployment automation and pod-health-monitor
#   to prevent race conditions, enable manual mode during maintenance, and provide
#   cluster health visibility via JSON API and visual dashboard.
#
# CORE FUNCTIONS:
#   - Namespace safety (prevent cross-environment operations)
#   - MANUAL_MODE circuit breaker (disable auto-heal during deployments)
#   - Cluster health snapshot API (JSON + visual dashboard)
#   - Deployment state coordination (begin/end lifecycle)
#   - Emergency maintenance orchestration
#
# DEPENDENCIES:
#   - logging.sh (log_* functions)
#   - validation.sh (resource validation)
#   - cluster-health.sh (send_notification)
#
# USAGE:
#   source ./openshift/scripts/utils/coordination.sh
#
#   # Enable manual mode for maintenance
#   set_manual_mode "true" "$DEPLOY_NAMESPACE" "Database upgrade" 120
#
#   # Query cluster health
#   query_cluster_health "$DEPLOY_NAMESPACE"
#
#   # Deployment lifecycle
#   begin_deployment "$DEPLOY_NAMESPACE" "mariadb-galera-upgrade"
#   # ... perform deployment ...
#   end_deployment "$DEPLOY_NAMESPACE" "true"
#
# RELATED DOCS:
#   - docs/pod-health-monitor-coordination-strategy.md
#   - docs/galera-deployment-best-practices.md
# =============================================================================

# =============================================================================
# NAMESPACE SAFETY: Prevent Cross-Environment Impact
# =============================================================================
# All operations are locked to the current oc project. Hardcoded namespace
# parameters are validated against current context. This prevents accidental
# production impact when troubleshooting dev/test environments.
#
# Example: If logged into 950003-dev, attempting to operate on 950003-prod
#          will be blocked with an error.
# =============================================================================

get_current_namespace() {
  local current_ns

  # 1. In-cluster: read from mounted service account (authoritative in pods)
  current_ns=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)

  # 2. Fallback: oc project context (GH runners, local dev)
  if [[ -z "$current_ns" ]]; then
    current_ns=$(oc project -q 2>/dev/null)
  fi

  if [[ -z "$current_ns" ]]; then
    log_error "Not logged into OpenShift or no current project set"
    return 1
  fi

  echo "$current_ns"
}

# =============================================================================
# ensure_openshift_auth - Unified auth for GH Actions + pod-health-monitor
# =============================================================================
# Works in both execution contexts:
#   - GH runner: oc login already done by workflow step, validates namespace
#   - Pod/container: authenticates via SA token or OPENSHIFT_TOKEN env var
#
# Behavior:
#   1. Detects namespace (SA file → oc project → DEPLOY_NAMESPACE env)
#   2. Validates caller-provided DEPLOY_NAMESPACE matches detected context
#   3. Authenticates if needed (no-op when already logged in)
#   4. Exports DEPLOY_NAMESPACE and NAMESPACE for downstream scripts
#
# Returns: 0 on success, 1 on failure (logs error details)
# =============================================================================
ensure_openshift_auth() {
  # Save caller-provided namespace (GH Actions sets DEPLOY_NAMESPACE as env var)
  local requested_ns="${DEPLOY_NAMESPACE:-}"

  # Detect actual namespace
  local detected_ns
  detected_ns=$(get_current_namespace 2>/dev/null || true)

  if [[ -z "$detected_ns" ]]; then
    # Last resort: use caller-provided DEPLOY_NAMESPACE if detection failed
    # (auth hasn't been set up yet — common in pod-health-monitor)
    detected_ns="$requested_ns"
  fi

  if [[ -z "$detected_ns" ]]; then
    log_error "Cannot detect namespace (no service account, oc login, or DEPLOY_NAMESPACE)"
    return 1
  fi

  # Set namespace for galera_setup_auth (it reads DEPLOY_NAMESPACE)
  export DEPLOY_NAMESPACE="$detected_ns"
  export NAMESPACE="$detected_ns"

  # Authenticate with OpenShift cluster
  if [[ "$(type -t galera_setup_auth)" == "function" ]]; then
    if ! galera_setup_auth; then
      log_error "OpenShift authentication failed"
      return 1
    fi
  else
    # No galera_setup_auth available — verify oc is already working
    if ! oc whoami >/dev/null 2>&1; then
      log_error "Not authenticated to OpenShift and galera_setup_auth not available"
      return 1
    fi
  fi

  # Re-detect namespace post-auth (oc project may have been set by galera_setup_auth)
  detected_ns=$(get_current_namespace 2>/dev/null || echo "$detected_ns")

  # Safety: validate caller-provided namespace matches detected context
  if [[ -n "$requested_ns" && "$requested_ns" != "$detected_ns" ]]; then
    log_error "NAMESPACE MISMATCH"
    log_error "  Requested: $requested_ns"
    log_error "  Detected:  $detected_ns"
    log_error "SAFETY LOCK: Cannot operate across namespaces"
    return 1
  fi

  # Export canonical namespace for all downstream usage
  export DEPLOY_NAMESPACE="$detected_ns"
  export NAMESPACE="$detected_ns"

  log_debug "Authenticated to namespace: $detected_ns"
  return 0
}

validate_namespace() {
  local requested_ns="$1"
  local current_ns
  current_ns=$(get_current_namespace) || return 1

  if [[ "$requested_ns" != "$current_ns" ]]; then
    log_error "🚨 NAMESPACE MISMATCH DETECTED"
    log_error "   Requested: $requested_ns"
    log_error "   Current:   $current_ns"
    log_error ""
    log_error "SAFETY LOCK: Cannot operate on different namespace"
    log_error "To operate on $requested_ns, first run:"
    log_error "  oc project $requested_ns"
    return 1
  fi

  log_debug "Namespace validated: $current_ns"
  return 0
}

safe_namespace_operation() {
  local operation_name="$1"
  local target_namespace="$2"
  shift 2
  local operation_function="$@"

  # Auto-detect if no namespace specified
  if [[ -z "$target_namespace" ]]; then
    target_namespace=$(get_current_namespace) || return 1
    log_debug "Auto-detected namespace: $target_namespace"
  fi

  # Validate namespace matches current context
  if ! validate_namespace "$target_namespace"; then
    log_error "Operation '$operation_name' blocked for safety"
    return 1
  fi

  # Execute operation
  log_debug "Executing: $operation_name in $target_namespace"
  eval "$operation_function"
}

# =============================================================================
# MANUAL_MODE: Circuit Breaker for Auto-Heal
# =============================================================================
# Enables/disables pod-health-monitor auto-healing via ConfigMap.
# No pod restart required - dynamic configuration.
#
# Timeouts (Context-Aware):
#   - Right-sizing: 30 minutes
#   - Database upgrade: 2 hours (default)
#   - Major version upgrade: 4 hours
#   - Emergency: Until manual disable (timeout=0)
# =============================================================================

set_manual_mode() {
  local enable="$1"  # "true" or "false"
  local namespace="${2:-}"
  local reason="${3:-Manual intervention}"
  local timeout_minutes="${4:-120}"  # Default: 2 hours

  # Namespace safety
  namespace="${namespace:-$(get_current_namespace)}"
  validate_namespace "$namespace" || return 1

  log_info "Setting MANUAL_MODE=$enable (reason: $reason, timeout: ${timeout_minutes}m)"

  # Calculate absolute timeout timestamp
  local timeout_timestamp
  if [[ "$enable" == "true" && "$timeout_minutes" -gt 0 ]]; then
    timeout_timestamp=$(date -u -d "+${timeout_minutes} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
                        date -u -v "+${timeout_minutes}M" +%Y-%m-%dT%H:%M:%SZ)
  else
    timeout_timestamp=""  # No timeout when disabling or timeout=0
  fi

  # Create/update ConfigMap with timeout info
  oc create configmap pod-health-monitor-config \
    --from-literal=manual_mode="$enable" \
    --from-literal=manual_mode_reason="$reason" \
    --from-literal=manual_mode_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --from-literal=manual_mode_timeout="$timeout_timestamp" \
    --from-literal=manual_mode_timeout_minutes="$timeout_minutes" \
    --dry-run=client -o yaml | oc apply -f - -n "$namespace"

  # Label for discovery
  oc label configmap pod-health-monitor-config \
    app=pod-health-monitor --overwrite -n "$namespace" 2>/dev/null || true

  if [[ "$enable" == "true" ]]; then
    log_success "MANUAL_MODE enabled (expires: $timeout_timestamp)"
  else
    log_success "MANUAL_MODE disabled (auto-heal re-enabled)"
  fi
}

get_manual_mode() {
  local namespace="${1:-$(get_current_namespace)}"

  oc get configmap pod-health-monitor-config \
    -n "$namespace" \
    -o jsonpath='{.data.manual_mode}' 2>/dev/null || echo "false"
}

check_manual_mode_timeout() {
  local namespace="${1:-$(get_current_namespace)}"

  local manual_mode
  manual_mode=$(get_manual_mode "$namespace")

  if [[ "$manual_mode" != "true" ]]; then
    return 0
  fi

  # Get timeout timestamp from ConfigMap
  local timeout_timestamp
  timeout_timestamp=$(oc get configmap pod-health-monitor-config \
    -n "$namespace" \
    -o jsonpath='{.data.manual_mode_timeout}' 2>/dev/null)

  if [[ -z "$timeout_timestamp" || "$timeout_timestamp" == "null" || "$timeout_timestamp" == "" ]]; then
    log_debug "No timeout set for MANUAL_MODE (manual disable required)"
    return 0
  fi

  # Check if timeout exceeded
  local current_epoch timeout_epoch
  current_epoch=$(date -u +%s)
  timeout_epoch=$(date -u -d "$timeout_timestamp" +%s 2>/dev/null || \
                  date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$timeout_timestamp" +%s 2>/dev/null || echo "0")

  if [[ $current_epoch -gt $timeout_epoch ]]; then
    local elapsed_minutes=$(( (current_epoch - timeout_epoch) / 60 ))
    log_warn "⚠️ MANUAL_MODE timeout exceeded by ${elapsed_minutes} minutes"

    send_notification "MANUAL_MODE_TIMEOUT" \
      "MANUAL_MODE Auto-Disabled (Timeout)" \
      "MANUAL_MODE was enabled for longer than expected. Auto-disabling. Original reason: $(oc get configmap pod-health-monitor-config -n "$namespace" -o jsonpath='{.data.manual_mode_reason}' 2>/dev/null)" \
      "warning" "$namespace"

    set_manual_mode "false" "$namespace" "Timeout exceeded"
    return 1  # Indicate timeout occurred
  fi

  return 0
}

# =============================================================================
# CLUSTER HEALTH SNAPSHOT API
# =============================================================================
# Generates JSON snapshot of cluster state for deployment coordination.
# Provides visibility into component health, maintenance mode status, and
# deployment activity.
# =============================================================================

generate_cluster_health_snapshot() {
  local namespace="${1:-$(get_current_namespace)}"
  local output_file="${2:-/tmp/cluster-health.json}"

  log_debug "Generating cluster health snapshot..."

  # Get MANUAL_MODE state
  local manual_mode manual_reason
  manual_mode=$(get_manual_mode "$namespace")
  manual_reason=$(oc get configmap pod-health-monitor-config \
    -n "$namespace" \
    -o jsonpath='{.data.manual_mode_reason}' 2>/dev/null || echo "N/A")

  # Detect deployment activity
  local deployment_active="false"
  if detect_deployment_activity "$namespace" 2>/dev/null; then
    deployment_active="true"
  fi

  # Check maintenance mode status
  local maint_route maint_pod maint_config
  maint_route=$(oc get route moodle -n "$namespace" \
    -o jsonpath='{.metadata.annotations.maintenance-mode}' 2>/dev/null || echo "false")

  maint_pod=$(oc get pod -l app=maintenance-message -n "$namespace" \
    -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "NotFound")

  # TODO: Check Moodle config.php maintenance mode (would need exec into php pod)
  maint_config="unknown"

  # Galera health (use existing check_galera_cluster_health if available)
  local galera_status="unknown" galera_replicas="0/0" galera_synced="unknown" galera_split_brain="unknown"
  if command -v check_galera_cluster_health &>/dev/null; then
    # Get expected replica count from StatefulSet
    local galera_expected
    galera_expected=$(oc get sts mariadb-galera -n "$namespace" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

    # Only run health check if StatefulSet exists
    if [[ "$galera_expected" -gt 0 ]]; then
      check_galera_cluster_health "app.kubernetes.io/name=mariadb-galera" "$namespace" "$galera_expected" >/dev/null 2>&1
      local galera_health_code=$?
      case $galera_health_code in
        0) galera_status="healthy"; galera_synced="true"; galera_split_brain="false" ;;
        1) galera_status="unhealthy"; galera_synced="false"; galera_split_brain="false" ;;
        2) galera_status="split-brain"; galera_synced="false"; galera_split_brain="true" ;;
      esac
    fi

    local galera_running
    galera_running=$(oc get pods -l app.kubernetes.io/name=mariadb-galera \
      --field-selector=status.phase=Running -n "$namespace" \
      -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
    galera_replicas="${galera_running}/${galera_expected}"
  fi

  # PHP health
  local php_replicas="0/0" php_status="unknown"
  if oc get deployment php -n "$namespace" &>/dev/null 2>&1; then
    local php_running php_expected
    php_running=$(oc get pods -l deployment=php --field-selector=status.phase=Running \
      -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | wc -w)
    php_expected=$(oc get deployment php -n "$namespace" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    php_replicas="${php_running}/${php_expected}"
    [[ "$php_running" -eq "$php_expected" && "$php_expected" -gt 0 ]] && php_status="healthy" || php_status="degraded"
  fi

  # Redis health
  local redis_status="unknown"
  if oc exec deployment/redis -n "$namespace" -- redis-cli PING 2>/dev/null | grep -q PONG; then
    redis_status="healthy"
  else
    redis_status="unhealthy"
  fi

  # Build JSON
  cat > "$output_file" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "namespace": "$namespace",
  "mode": "$manual_mode",
  "manual_mode_reason": "$manual_reason",
  "deployment_detected": $deployment_active,
  "maintenance_mode": {
    "route_disabled": $maint_route,
    "message_pod": "$maint_pod",
    "moodle_config": "$maint_config"
  },
  "cluster_health": {
    "mariadb-galera": {
      "status": "$galera_status",
      "replicas": "$galera_replicas",
      "synced": $galera_synced,
      "split_brain": $galera_split_brain
    },
    "php": {
      "status": "$php_status",
      "replicas": "$php_replicas"
    },
    "redis": {
      "status": "$redis_status"
    }
  },
  "warnings": [],
  "errors": []
}
EOF

  log_debug "Health snapshot written to $output_file"
  return 0
}

query_cluster_health() {
  local namespace="${1:-$(get_current_namespace)}"
  local component="${2:-all}"  # "all", "mariadb-galera", "php", "redis"

  # Generate latest health snapshot
  generate_cluster_health_snapshot "$namespace" "/tmp/health-query.json" > /dev/null 2>&1

  if [[ "$component" == "all" ]]; then
    cat /tmp/health-query.json
  else
    jq ".cluster_health.\"$component\"" /tmp/health-query.json 2>/dev/null || echo "{}"
  fi
}

print_health_dashboard() {
  local json_file="${1:-/tmp/cluster-health.json}"

  if [[ ! -f "$json_file" ]]; then
    return 1
  fi

  echo ""
  echo "╔════════════════════════════════════════════════════════════════════╗"
  echo "║           CLUSTER HEALTH DASHBOARD (MONITORING POD)               ║"
  echo "╠════════════════════════════════════════════════════════════════════╣"

  local timestamp mode deployment_active
  timestamp=$(jq -r '.timestamp' "$json_file" 2>/dev/null || echo "unknown")
  mode=$(jq -r '.mode' "$json_file" 2>/dev/null || echo "false")
  deployment_active=$(jq -r '.deployment_detected' "$json_file" 2>/dev/null || echo "false")

  echo "║ Timestamp: $timestamp"
  if [[ "$mode" == "true" ]]; then
    echo "║ Mode: MANUAL (AUTO-HEAL DISABLED)"
  else
    echo "║ Mode: AUTO (AUTO-HEAL ENABLED)"
  fi
  echo "║ Deployment Active: $deployment_active"
  echo "╠════════════════════════════════════════════════════════════════════╣"
  echo "║ COMPONENT STATUS"
  echo "╠════════════════════════════════════════════════════════════════════╣"

  # Galera
  local galera_status galera_replicas galera_split_brain
  galera_status=$(jq -r '.cluster_health."mariadb-galera".status' "$json_file" 2>/dev/null || echo "unknown")
  galera_replicas=$(jq -r '.cluster_health."mariadb-galera".replicas' "$json_file" 2>/dev/null || echo "0/0")
  galera_split_brain=$(jq -r '.cluster_health."mariadb-galera".split_brain' "$json_file" 2>/dev/null || echo "unknown")

  local galera_icon="✅"
  [[ "$galera_status" == "unhealthy" ]] && galera_icon="⚠️ "
  [[ "$galera_split_brain" == "true" ]] && galera_icon="🚨"

  printf "║ %s MariaDB Galera: %-20s Replicas: %-10s ║\n" \
    "$galera_icon" "$galera_status" "$galera_replicas"

  # PHP
  local php_status php_replicas
  php_status=$(jq -r '.cluster_health.php.status' "$json_file" 2>/dev/null || echo "unknown")
  php_replicas=$(jq -r '.cluster_health.php.replicas' "$json_file" 2>/dev/null || echo "0/0")

  local php_icon="✅"
  [[ "$php_status" != "healthy" ]] && php_icon="⚠️ "

  printf "║ %s PHP:              %-20s Replicas: %-10s ║\n" \
    "$php_icon" "$php_status" "$php_replicas"

  # Redis
  local redis_status
  redis_status=$(jq -r '.cluster_health.redis.status' "$json_file" 2>/dev/null || echo "unknown")

  local redis_icon="✅"
  [[ "$redis_status" != "healthy" ]] && redis_icon="⚠️ "

  printf "║ %s Redis:            %-20s                       ║\n" \
    "$redis_icon" "$redis_status"

  echo "╠════════════════════════════════════════════════════════════════════╣"
  echo "║ MAINTENANCE MODE"
  echo "╠════════════════════════════════════════════════════════════════════╣"

  local maint_route maint_pod
  maint_route=$(jq -r '.maintenance_mode.route_disabled' "$json_file" 2>/dev/null || echo "false")
  maint_pod=$(jq -r '.maintenance_mode.message_pod' "$json_file" 2>/dev/null || echo "NotFound")

  printf "║ Route Disabled: %-10s  Message Pod: %-20s ║\n" \
    "$maint_route" "$maint_pod"

  echo "╚════════════════════════════════════════════════════════════════════╝"
  echo ""
}

# =============================================================================
# DEPLOYMENT ACTIVITY DETECTION
# =============================================================================
# Auto-detects deployment/maintenance activity to enable MANUAL_MODE.
# =============================================================================

detect_deployment_activity() {
  local namespace="${1:-$(get_current_namespace)}"

  # Check 1: Active rollouts
  local rollouts
  rollouts=$(oc get deployments -n "$namespace" -o json 2>/dev/null | \
    jq -r '.items[] | select(.status.conditions[]? |
    select(.type=="Progressing" and .status=="True" and .reason=="ReplicaSetUpdated")) |
    .metadata.name' 2>/dev/null)

  if [[ -n "$rollouts" ]]; then
    log_debug "Active rollouts detected: $rollouts"
    return 0
  fi

  # Check 2: Maintenance message pod running
  if oc get pod -l app=maintenance-message -n "$namespace" 2>/dev/null | grep -q Running; then
    log_debug "Maintenance message pod detected"
    return 0
  fi

  # Check 3: Route in maintenance mode
  local route_maint
  route_maint=$(oc get route moodle -n "$namespace" \
    -o jsonpath='{.metadata.annotations.maintenance-mode}' 2>/dev/null)

  if [[ "$route_maint" == "true" ]]; then
    log_debug "Route maintenance mode detected"
    return 0
  fi

  # Check 4: Deployment ConfigMap flag (explicit signal)
  local deploy_flag
  deploy_flag=$(oc get configmap deployment-state -n "$namespace" \
    -o jsonpath='{.data.deployment_active}' 2>/dev/null)

  if [[ "$deploy_flag" == "true" || "$deploy_flag" == "maintenance" || "$deploy_flag" == "emergency" ]]; then
    log_debug "Deployment flag detected in ConfigMap: $deploy_flag"
    return 0
  fi

  return 1
}

# =============================================================================
# DEPLOYMENT LIFECYCLE COORDINATION
# =============================================================================
# Wrapper functions for begin/end deployment to coordinate with pod-health-monitor.
# =============================================================================

begin_deployment() {
  local namespace="${1:-$(get_current_namespace)}"
  local deployment_name="${2:-manual-deployment}"
  local timeout_minutes="${3:-120}"  # Default: 2 hours

  # Namespace safety
  validate_namespace "$namespace" || return 1

  log_header "BEGIN DEPLOYMENT: $deployment_name"

  # Step 1: Signal deployment start
  oc create configmap deployment-state \
    --from-literal=deployment_active="true" \
    --from-literal=deployment_name="$deployment_name" \
    --from-literal=deployment_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --dry-run=client -o yaml | oc apply -f - -n "$namespace"

  # Step 2: Enable MANUAL_MODE
  set_manual_mode "true" "$namespace" "Deployment: $deployment_name" "$timeout_minutes"

  # Wait for pod-health-monitor to acknowledge
  local wait_count=0
  while [[ $wait_count -lt 15 ]]; do
    local current_mode
    current_mode=$(get_manual_mode "$namespace")
    if [[ "$current_mode" == "true" ]]; then
      log_success "pod-health-monitor MANUAL_MODE enabled"
      break
    fi
    sleep 2
    wait_count=$((wait_count + 1))
  done

  log_success "Deployment started - auto-heal disabled"
}

end_deployment() {
  local namespace="${1:-$(get_current_namespace)}"
  local success="${2:-true}"  # "true" or "false"

  # Namespace safety
  validate_namespace "$namespace" || return 1

  log_header "END DEPLOYMENT"

  # Step 1: Query final health status
  log_info "Querying final cluster health..."
  generate_cluster_health_snapshot "$namespace" "/tmp/final-health.json" 2>/dev/null || true

  if [[ -f "/tmp/final-health.json" ]]; then
    local galera_status
    galera_status=$(jq -r '.cluster_health."mariadb-galera".status' /tmp/final-health.json 2>/dev/null || echo "unknown")

    if [[ "$galera_status" != "healthy" && "$success" == "true" ]]; then
      log_error "Cluster unhealthy after deployment - leaving MANUAL_MODE enabled"
      log_error "Run manual verification before disabling MANUAL_MODE"
      return 1
    fi
  fi

  # Step 2: Disable MANUAL_MODE
  set_manual_mode "false" "$namespace" "Deployment complete"

  # Step 3: Clear deployment state
  oc delete configmap deployment-state -n "$namespace" --ignore-not-found=true

  log_success "Deployment complete - auto-heal re-enabled"
}

# =============================================================================
# EMERGENCY MAINTENANCE INTEGRATION
# =============================================================================
# Enhanced emergency maintenance with coordination layer.
# Integrates with existing emergency mode functions.
# =============================================================================

enable_emergency_maintenance() {
  local namespace="$1"
  local reason="$2"
  local moodle_maintenance="${3:-YES}"
  local openshift_maintenance="${4:-YES}"
  local timeout_minutes="${5:-240}"  # 4 hours default for emergencies

  # Namespace safety
  validate_namespace "$namespace" || return 1

  log_header "EMERGENCY MAINTENANCE"
  log_error "Reason: $reason"

  # Enable MANUAL_MODE first
  set_manual_mode "true" "$namespace" "Emergency: $reason" "$timeout_minutes"

  # Set deployment state
  oc create configmap deployment-state \
    --from-literal=deployment_active="emergency" \
    --from-literal=deployment_type="emergency_maintenance" \
    --from-literal=maintenance_reason="$reason" \
    --from-literal=maintenance_timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --dry-run=client -o yaml | oc apply -f - -n "$namespace"

  oc label configmap deployment-state app=pod-health-monitor --overwrite -n "$namespace" 2>/dev/null || true

  # Moodle CLI maintenance mode
  if [[ "$moodle_maintenance" == "YES" ]]; then
    log_info "Enabling Moodle maintenance mode..."
    local cron_pod
    cron_pod=$(oc get pods -l app=moodle-cron \
      --field-selector=status.phase=Running \
      -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$cron_pod" ]]; then
      if oc exec -n "$namespace" "$cron_pod" -- \
           php /var/www/html/admin/cli/maintenance.php --enable 2>&1; then
        log_success "Moodle maintenance mode enabled"
      else
        log_warn "Failed to enable Moodle maintenance mode (non-fatal)"
      fi
    else
      log_warn "No running cron pod found - cannot enable Moodle maintenance mode"
    fi
  fi

  # OpenShift route redirect
  if [[ "$openshift_maintenance" == "YES" ]]; then
    log_info "Enabling OpenShift maintenance mode..."

    if oc get deployment maintenance-message -n "$namespace" &>/dev/null; then
      # Scale up maintenance page
      oc scale deployment/maintenance-message -n "$namespace" --replicas=1
      oc rollout status deployment/maintenance-message -n "$namespace" --timeout=120s 2>/dev/null || true

      # Redirect routes
      local routes route
      routes=$(oc get routes -n "$namespace" -o jsonpath='{.items[*].metadata.name}')
      for route in $routes; do
        if oc patch route "$route" -n "$namespace" \
             -p '{"spec":{"to":{"name":"maintenance-message"}}}' 2>/dev/null; then
          log_success "  ✅ Patched route: $route → maintenance-message"
        else
          log_warn "  ⚠️ Failed to patch route: $route"
        fi
      done

      log_success "OpenShift maintenance mode enabled"
    else
      log_warn "maintenance-message deployment not found - deploying..."
      # Call deploy-maintenance-message.sh if available
      if [[ -f "$(dirname "${BASH_SOURCE[0]}")/../deploy-maintenance-message.sh" ]]; then
        bash "$(dirname "${BASH_SOURCE[0]}")/../deploy-maintenance-message.sh"
      else
        log_error "Cannot deploy maintenance message - script not found"
      fi
    fi
  fi

  send_notification "EMERGENCY_MAINTENANCE_ENABLED" \
    "🚨 Emergency Maintenance Mode" \
    "Emergency maintenance enabled. Reason: $reason. Site unavailable. MANUAL_MODE active." \
    "error" "$namespace"

  log_success "Emergency maintenance mode enabled"
}
