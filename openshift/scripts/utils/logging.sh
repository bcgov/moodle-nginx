#!/bin/bash
# =============================================================================
# logging.sh - Structured Logging Utilities
# =============================================================================
# PURPOSE:
#   Provides three-tier logging system (INFO/DEBUG/TRACE) with emoji icons,
#   error file logging, critical event tracking, and notification integration.
#
# LOGGING LEVELS:
#   - INFO: Always shown (user-facing progress updates)
#   - DEBUG: Shown when DEBUG_LEVEL=DEBUG or TRACE (troubleshooting detail)
#   - TRACE: Shown when DEBUG_LEVEL=TRACE (ultra-verbose command tracking)
#
# CORE FUNCTIONS:
#   - log_info(), log_success(), log_warn(), log_error() - Standard logging
#   - log_debug(), log_trace() - Debug-controlled logging
#   - log_critical_event() - Structured event logging for OpenShift events
#   - log_error_to_file() - Persistent error tracking
#
# USAGE:
#   source ./openshift/scripts/utils/logging.sh
#
#   log_info "Processing deployment..."
#   log_debug "Database connection: $DB_HOST:$DB_PORT"
#   log_success "Deployment complete!"
#
# ENVIRONMENT VARIABLES:
#   DEBUG_LEVEL - Controls verbosity (INFO|DEBUG|TRACE)
#
# RELATED DOCS:
#   - docs/logging-levels.md
# =============================================================================

# =============================================================================
# STANDARD LOGGING FUNCTIONS (Always Shown)
# =============================================================================

# Function to log info messages (always shown)
log_info() {
  echo "ℹ️  $*" >&2
}

# Function to log success messages (always shown)
log_success() {
  echo "✅ $*"
}

# Function to log warning messages (always shown)
log_warn() {
  echo "⚠️  $*" >&2
}

# Function to log error messages (always shown)
log_error() {
  echo "❌ $*" >&2
}

# Function to log section headers (always shown)
log_header() {
  echo "" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "  $*" >&2
  echo "═══════════════════════════════════════════════════════════════════" >&2
  echo "" >&2
}

# Function to log dividers (always shown)
log_divider() {
  echo "───────────────────────────────────────────────────────────────────" >&2
}

# Function to echo a label-value field (always shown)
echo_field() {
  local label="$1"
  local value="$2"
  local width="${3:-30}"  # Default label width

  printf "%-${width}s: %s\n" "$label" "$value" >&2
}

# =============================================================================
# DEBUG-LEVEL LOGGING (Controlled by DEBUG_LEVEL)
# =============================================================================

# Function to log debug messages only when DEBUG_LEVEL is set to DEBUG or TRACE
log_debug() {
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]] || [[ "${DEBUG_LEVEL}" == "TRACE" ]]; then
    echo "🔍 Debug: $*" >&2
  fi
}

# Function to log trace messages (ultra-verbose, command-level detail)
# Only shown when DEBUG_LEVEL=TRACE
log_trace() {
  if [[ "${DEBUG_LEVEL}" == "TRACE" ]]; then
    echo "🔬 Trace: $*" >&2
  fi
}

# =============================================================================
# ERROR FILE LOGGING (Persistent Error Tracking)
# =============================================================================

log_error_to_file() {
  local pod=$1
  local container=$2
  local error_line=$3
  local log_file=$4

  echo "Pod: $pod, Container: $container, Error: $error_line" >> "$log_file"
}

# =============================================================================
# POD LOG CHECKING (Used by Monitoring Scripts)
# =============================================================================

# Function to check logs for a single pod
check_pod_logs() {
  local pod=$1
  local namespace=$2
  local error_search_strings=${3:-"error"}
  local error_handler=${4:-delete_pod}
  local log_file="/tmp/logs/check-pod-logs.log"
  local tail_lines=${5:-100}  # Only check recent logs to avoid startup noise

  # Split the error_search_strings into an array
  IFS=',' read -r -a error_strings <<< "$error_search_strings"

  # Check for malformed variables
  if [[ -z "$pod" || -z "$namespace" ]]; then
    log_error "ERROR: pod or namespace is empty!"
    return 1
  fi

  # Get the list of containers in the pod
  CONTAINERS=$(oc get pod "$pod" -n "$namespace" -o jsonpath='{.spec.containers[*].name}')
  IFS=' ' read -r -a container_array <<< "$CONTAINERS"

  for container in "${container_array[@]}"; do
    LOGS=$(oc logs "$pod" -n "$namespace" -c "$container" --tail="$tail_lines")

    for error_search_string in "${error_strings[@]}"; do
      if echo "$LOGS" | grep -q "$error_search_string"; then
        if echo "$LOGS" | grep -q "Success"; then
          log_info "Connection was lost but reestablished. No need to restart the pod."
          continue
        else
          log_warn "Error found in pod logs: $error_search_string"
          $error_handler "$pod"
          return 1  # Return failure if an error was found and handled
        fi
      fi
    done
  done

  log_success "No errors found in pod: $pod"
  return 0  # Return success if no errors were found
}

# Function to check logs for all pods in a deployment
check_deployment_logs() {
  eval "declare -A deployments="${1#*=}
  local max_retries=15
  local retry_count=0
  local wait_time=60

  for deployment in "${!deployments[@]}"; do
    local error_search_strings=${deployments[$deployment]:-"error"}
    local error_handler=${3:-delete_pod}
    local total_errors=0

    log_info "Checking logs: $deployment"

    while true; do
      local errors_detected=0

      # Get the list of pods in the deployment
      PODS=$(oc get pods -l "$deployment" -o jsonpath='{.items[*].metadata.name}')

      # Check if PODS is empty
      if [ -z "$PODS" ]; then
        log_warn "No pods found for deployment: $deployment"
        break
      fi

      # Convert PODS to an array
      IFS=' ' read -r -a pod_array <<< "$PODS"
      # Get number of pods in the array
      total_pods=$(echo "$PODS" | wc -w)

      for pod in "${pod_array[@]}"; do
        log_info "Processing pod logs: $pod"

        if ! check_pod_logs "$pod" "$DEPLOY_NAMESPACE" "$error_search_strings" "$error_handler"; then
          errors_detected=$((errors_detected + 1))
          total_errors=$((total_errors + 1))

          # Wait for the pod to be fully restarted and stabilized
          log_info "Waiting for pod $pod to restart and stabilize..."
          sleep "$wait_time"
          oc wait --for=condition=Ready "pod/$pod" --timeout=300s
          break
        fi
      done

      if [ $errors_detected -eq 0 ]; then
        log_success "✔️ OK"
        break
      else
        log_error "Errors found: $total_errors."
        retry_count=$((retry_count + 1))
        if [ $retry_count -ge $max_retries ]; then
          log_error "Max retries reached. Exiting..."
          return 1
        fi
        log_info "Waiting for pods to restart and stabilize..."
        sleep "$wait_time"
      fi
    done

    if [ $total_errors -ne 0 ]; then
      log_error "Errors detected: $total_errors"
    fi
  done

  return 0
}

# =============================================================================
# STRUCTURED EVENT LOGGING (OpenShift Events & Notifications)
# =============================================================================

# Enhanced logging function for structured events
# Creates OpenShift events for cluster-wide visibility
log_critical_event() {
  local event_type="$1"
  local message="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local severity="${4:-warning}"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S UTC')

  # Use severity-appropriate label for log aggregation
  local label="EVENT"
  case "$severity" in
    "error"|"failure") label="CRITICAL_EVENT" ;;
    "warning")         label="WARNING_EVENT" ;;
    "healing"|"repair") label="HEALING_EVENT" ;;
    "success")         label="INFO_EVENT" ;;
    *)                 label="INFO_EVENT" ;;
  esac

  # Log to stdout with structured format for OpenShift log aggregation
  echo "${label}|${timestamp}|${namespace}|${event_type}|${message}"

  # Also log to OpenShift events for visibility in cluster
  if command -v oc >/dev/null 2>&1; then
    oc create event \
      --type=Warning \
      --reason="$event_type" \
      --message="$message" \
      --reporting-instance="check-pod-logs" \
      --reporting-component="galera-monitor" \
      2>/dev/null || true
  fi
}

# Function to send notifications matching GitHub workflow style
# Requires webhook_notification.json template
send_notification() {
  local event_type="$1"
  local title="$2"
  local message="$3"
  local severity="${4:-warning}"  # warning, error, success
  local namespace="${5:-$DEPLOY_NAMESPACE}"

  # Note: This function stub requires webhook configuration.
  # Full implementation delegated to coordination layer or workflow-specific scripts.
  # See: .github/workflows/*.yml for webhook integration examples
  #      Sysdig/webhook_notification.json for template structure

  log_debug "Notification: [$severity] $title - $message"

  # If WEBHOOK_URL is configured, send notification
  if [[ -n "${WEBHOOK_URL:-}" ]]; then
    log_trace "Sending webhook notification to: $WEBHOOK_URL"
    # TODO: Implement webhook POST with JSON template
    # curl -X POST "$WEBHOOK_URL" -H 'Content-Type: application/json' -d @webhook_notification.json
  fi
}

# =============================================================================
# HELPER FUNCTIONS FOR STRUCTURED OUTPUT
# =============================================================================

# Print a table row with consistent column widths
print_table_row() {
  local col1="$1"
  local col2="$2"
  local col3="${3:-}"
  local col4="${4:-}"

  printf "│ %-30s │ %-20s │ %-15s │ %-15s │\n" \
    "$col1" "$col2" "$col3" "$col4" >&2
}

# Print a table header separator
print_table_separator() {
  echo "├────────────────────────────────┼──────────────────────┼─────────────────┼─────────────────┤" >&2
}

# Print a table top border
print_table_top() {
  echo "┌────────────────────────────────┬──────────────────────┬─────────────────┬─────────────────┐" >&2
}

# Print a table bottom border
print_table_bottom() {
  echo "└────────────────────────────────┴──────────────────────┴─────────────────┴─────────────────┘" >&2
}
