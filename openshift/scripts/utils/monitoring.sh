#!/bin/bash

# Monitoring and Notification Utilities Module
# Contains notification systems, monitoring helpers, and alerting functions

# =============================================================================
# NOTIFICATION CONFIGURATION
# =============================================================================

# Default notification settings
declare -A NOTIFICATION_CONFIG=(
  ["webhook_timeout"]="30"
  ["max_retries"]="3"
  ["retry_delay"]="5"
  ["message_max_length"]="4000"
  ["enable_markdown"]="true"
  ["default_severity"]="info"
)

configure_notifications() {
  local webhook_url="$1"
  local channel="${2:-#deployments}"
  local username="${3:-OpenShift-Bot}"
  local emoji="${4:-:rocket:}"
  
  export NOTIFICATION_WEBHOOK_URL="$webhook_url"
  export NOTIFICATION_CHANNEL="$channel"
  export NOTIFICATION_USERNAME="$username"
  export NOTIFICATION_EMOJI="$emoji"
  
  log_debug "Notifications configured for channel: $channel"
}

# =============================================================================
# MESSAGE FORMATTING
# =============================================================================

format_notification_message() {
  local title="$1"
  local message="$2"
  local severity="${3:-info}"
  local environment="${4:-}"
  local component="${5:-}"
  local additional_fields="$6"
  
  # Determine color based on severity
  local color
  case "$severity" in
    "success"|"good") color="good" ;;
    "warning"|"warn") color="warning" ;;
    "error"|"danger") color="danger" ;;
    "info"|*) color="#36a64f" ;;
  esac
  
  # Truncate message if too long
  local max_length="${NOTIFICATION_CONFIG[message_max_length]}"
  if [ ${#message} -gt "$max_length" ]; then
    message="${message:0:$((max_length-20))}...(truncated)"
  fi
  
  # Build notification payload
  local payload="{
    \"channel\": \"${NOTIFICATION_CHANNEL:-#deployments}\",
    \"username\": \"${NOTIFICATION_USERNAME:-OpenShift-Bot}\",
    \"icon_emoji\": \"${NOTIFICATION_EMOJI:-:rocket:}\",
    \"attachments\": [{
      \"color\": \"$color\",
      \"title\": \"$title\",
      \"text\": \"$message\",
      \"footer\": \"OpenShift Deployment Pipeline\",
      \"ts\": $(date +%s)"
  
  # Add environment field if provided
  if [ -n "$environment" ]; then
    payload="$payload,
      \"fields\": [{
        \"title\": \"Environment\",
        \"value\": \"$environment\",
        \"short\": true
      }"
    
    # Add component field if provided
    if [ -n "$component" ]; then
      payload="$payload,{
        \"title\": \"Component\",
        \"value\": \"$component\",
        \"short\": true
      }"
    fi
    
    # Add additional fields if provided
    if [ -n "$additional_fields" ]; then
      payload="$payload,$additional_fields"
    fi
    
    payload="$payload]"
  fi
  
  payload="$payload}]}"
  
  echo "$payload"
}

# =============================================================================
# NOTIFICATION DELIVERY
# =============================================================================

send_notification() {
  local title="$1"
  local message="$2"
  local severity="${3:-info}"
  local environment="${4:-}"
  local component="${5:-}"
  local additional_fields="$6"
  
  # Check if webhook URL is configured
  if [ -z "$NOTIFICATION_WEBHOOK_URL" ]; then
    log_debug "No notification webhook configured, skipping notification"
    return 0
  fi
  
  # Format the message
  local payload=$(format_notification_message "$title" "$message" "$severity" "$environment" "$component" "$additional_fields")
  
  # Send notification with retries
  local max_retries="${NOTIFICATION_CONFIG[max_retries]}"
  local retry_delay="${NOTIFICATION_CONFIG[retry_delay]}"
  local timeout="${NOTIFICATION_CONFIG[webhook_timeout]}"
  
  for attempt in $(seq 1 "$max_retries"); do
    log_debug "Sending notification (attempt $attempt/$max_retries)..."
    
    local response
    local exit_code
    
    if command -v curl >/dev/null 2>&1; then
      response=$(curl -s -X POST \
        --connect-timeout "$timeout" \
        --max-time "$timeout" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$NOTIFICATION_WEBHOOK_URL" 2>&1)
      exit_code=$?
    else
      log_error "curl not available for sending notifications"
      return 1
    fi
    
    if [ $exit_code -eq 0 ]; then
      log_debug "Notification sent successfully"
      return 0
    else
      log_warn "Notification attempt $attempt failed: $response"
      if [ $attempt -lt "$max_retries" ]; then
        log_debug "Retrying in ${retry_delay}s..."
        sleep "$retry_delay"
      fi
    fi
  done
  
  log_error "Failed to send notification after $max_retries attempts"
  return 1
}

# =============================================================================
# DEPLOYMENT NOTIFICATIONS
# =============================================================================

notify_deployment_start() {
  local environment="$1"
  local component="$2"
  local version="${3:-unknown}"
  local initiated_by="${4:-${GITHUB_ACTOR:-System}}"
  
  local title="🚀 Deployment Started"
  local message="Deployment initiated for **$component** in **$environment** environment"
  
  # Add version info if available
  if [ "$version" != "unknown" ]; then
    message="$message\\nVersion: \`$version\`"
  fi
  
  # Add initiator info
  message="$message\\nInitiated by: $initiated_by"
  
  # Add additional context
  local additional_fields=""
  if [ -n "$GITHUB_RUN_ID" ]; then
    additional_fields="{
      \"title\": \"Build\",
      \"value\": \"[$GITHUB_RUN_ID](https://github.com/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID)\",
      \"short\": true
    }"
  fi
  
  send_notification "$title" "$message" "info" "$environment" "$component" "$additional_fields"
}

notify_deployment_success() {
  local environment="$1"
  local component="$2"
  local version="${3:-unknown}"
  local duration="${4:-}"
  local url="${5:-}"
  
  local title="✅ Deployment Successful"
  local message="**$component** has been successfully deployed to **$environment**"
  
  # Add version info
  if [ "$version" != "unknown" ]; then
    message="$message\\nVersion: \`$version\`"
  fi
  
  # Add duration if available
  if [ -n "$duration" ]; then
    message="$message\\nDuration: $duration"
  fi
  
  # Add URL if available
  if [ -n "$url" ]; then
    message="$message\\nURL: $url"
  fi
  
  send_notification "$title" "$message" "success" "$environment" "$component"
}

notify_deployment_failure() {
  local environment="$1"
  local component="$2"
  local version="${3:-unknown}"
  local error_message="$4"
  local logs_url="${5:-}"
  
  local title="❌ Deployment Failed"
  local message="**$component** deployment to **$environment** has failed"
  
  # Add version info
  if [ "$version" != "unknown" ]; then
    message="$message\\nVersion: \`$version\`"
  fi
  
  # Add error message
  if [ -n "$error_message" ]; then
    # Truncate long error messages
    if [ ${#error_message} -gt 200 ]; then
      error_message="${error_message:0:200}..."
    fi
    message="$message\\nError: \`$error_message\`"
  fi
  
  # Add logs URL if available
  if [ -n "$logs_url" ]; then
    message="$message\\nLogs: $logs_url"
  fi
  
  send_notification "$title" "$message" "error" "$environment" "$component"
}

# =============================================================================
# SECURITY NOTIFICATIONS
# =============================================================================

notify_security_issue() {
  local severity="$1"
  local component="$2"
  local issue_type="$3"
  local description="$4"
  local remediation="${5:-}"
  
  local title
  local color_severity
  
  case "$severity" in
    "critical")
      title="🔴 CRITICAL Security Issue Detected"
      color_severity="danger"
      ;;
    "high")
      title="🟠 HIGH Security Issue Detected"
      color_severity="warning"
      ;;
    "medium")
      title="🟡 MEDIUM Security Issue Detected"
      color_severity="warning"
      ;;
    "low")
      title="🔵 LOW Security Issue Detected"
      color_severity="info"
      ;;
    *)
      title="🔍 Security Issue Detected"
      color_severity="warning"
      ;;
  esac
  
  local message="**Issue Type:** $issue_type\\n**Component:** $component\\n**Description:** $description"
  
  if [ -n "$remediation" ]; then
    message="$message\\n**Recommended Action:** $remediation"
  fi
  
  # Add timestamp and urgency
  message="$message\\n**Detected:** $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  
  # Add additional fields for security context
  local additional_fields="{
    \"title\": \"Severity Level\",
    \"value\": \"$(echo "$severity" | tr '[:lower:]' '[:upper:]')\",
    \"short\": true
  }"
  
  send_notification "$title" "$message" "$color_severity" "" "$component" "$additional_fields"
}

notify_vulnerability_scan_results() {
  local total_vulnerabilities="$1"
  local critical_count="$2"
  local high_count="$3"
  local medium_count="$4"
  local low_count="$5"
  local scan_type="${6:-NPM Audit}"
  local component="${7:-Application}"
  
  local title="🔍 Security Scan Results"
  local severity="info"
  
  # Determine severity based on findings
  if [ "$critical_count" -gt 0 ]; then
    severity="error"
    title="🔴 Critical Vulnerabilities Found"
  elif [ "$high_count" -gt 0 ]; then
    severity="warning"
    title="🟠 High-Risk Vulnerabilities Found"
  elif [ "$medium_count" -gt 0 ]; then
    severity="warning"
    title="🟡 Medium-Risk Vulnerabilities Found"
  elif [ "$total_vulnerabilities" -eq 0 ]; then
    title="✅ No Vulnerabilities Found"
    severity="success"
  fi
  
  local message="**$scan_type** scan completed for **$component**"
  
  if [ "$total_vulnerabilities" -gt 0 ]; then
    message="$message\\n**Total Issues:** $total_vulnerabilities"
    message="$message\\n**Breakdown:**"
    message="$message\\n  • Critical: $critical_count"
    message="$message\\n  • High: $high_count"
    message="$message\\n  • Medium: $medium_count"
    message="$message\\n  • Low: $low_count"
  else
    message="$message\\n**Result:** No vulnerabilities detected ✅"
  fi
  
  send_notification "$title" "$message" "$severity" "" "$component"
}

# =============================================================================
# MONITORING HELPERS
# =============================================================================

check_deployment_health() {
  local namespace="$1"
  local component="$2"
  local health_endpoint="${3:-/health}"
  local notify_on_failure="${4:-true}"
  
  log_info "Checking health of $component in $namespace..."
  
  # Inline health check function (moved from deployment.sh)
  check_service_health() {
    local service_name="$1"
    local namespace="${2:-default}"
    local health_endpoint="${3:-/health}"
    local expected_status="${4:-200}"
    
    log_info "Checking health of service: $service_name"
    
    # Get service URL
    local service_url
    if oc get route "$service_name" -n "$namespace" >/dev/null 2>&1; then
      service_url=$(oc get route "$service_name" -n "$namespace" -o jsonpath='{.spec.host}')
      service_url="https://${service_url}${health_endpoint}"
    elif oc get service "$service_name" -n "$namespace" >/dev/null 2>&1; then
      local service_ip=$(oc get service "$service_name" -n "$namespace" -o jsonpath='{.spec.clusterIP}')
      local service_port=$(oc get service "$service_name" -n "$namespace" -o jsonpath='{.spec.ports[0].port}')
      service_url="http://${service_ip}:${service_port}${health_endpoint}"
    else
      log_error "Service '$service_name' not found in namespace '$namespace'"
      return 1
    fi
    
    log_debug "Health check URL: $service_url"
    
    # Perform health check
    local response_code
    if command -v curl >/dev/null 2>&1; then
      response_code=$(curl -s -o /dev/null -w "%{http_code}" "$service_url" --connect-timeout 10 --max-time 30)
    else
      log_error "curl not available for health check"
      return 1
    fi
    
    if [ "$response_code" = "$expected_status" ]; then
      log_info "Service '$service_name' health check passed (HTTP $response_code)"
      return 0
    else
      log_error "Service '$service_name' health check failed (HTTP $response_code, expected $expected_status)"
      return 1
    fi
  }
  
  if check_service_health "$component" "$namespace" "$health_endpoint"; then
    log_info "Health check passed for $component"
    return 0
  else
    log_error "Health check failed for $component"
    
    if [ "$notify_on_failure" = "true" ]; then
      notify_deployment_failure "$namespace" "$component" "current" "Health check failed" ""
    fi
    
    return 1
  fi
}

monitor_deployment_progress() {
  local namespace="$1"
  local component="$2"
  local timeout="${3:-600}"
  local notify_progress="${4:-false}"
  
  local start_time=$(date +%s)
  local last_status=""
  
  log_info "Monitoring deployment progress for $component..."
  
  while true; do
    local current_time=$(date +%s)
    local elapsed=$((current_time - start_time))
    
    if [ $elapsed -gt $timeout ]; then
      log_error "Deployment monitoring timeout reached ($timeout seconds)"
      notify_deployment_failure "$namespace" "$component" "current" "Deployment timeout" ""
      return 1
    fi
    
    # Check deployment status
    local ready_replicas=$(oc get deployment "$component" -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    local desired_replicas=$(oc get deployment "$component" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)
    local current_status="${ready_replicas:-0}/${desired_replicas:-0}"
    
    # Notify on status change if requested
    if [ "$notify_progress" = "true" ] && [ "$current_status" != "$last_status" ]; then
      local duration=$((elapsed / 60))
      local progress_message="Deployment progress: $current_status replicas ready (${duration}m elapsed)"
      send_notification "📊 Deployment Progress" "$progress_message" "info" "$namespace" "$component"
      last_status="$current_status"
    fi
    
    # Check if deployment is complete
    if [ -n "$ready_replicas" ] && [ -n "$desired_replicas" ] && [ "$ready_replicas" -eq "$desired_replicas" ] && [ "$desired_replicas" -gt 0 ]; then
      local duration_minutes=$((elapsed / 60))
      local duration_seconds=$((elapsed % 60))
      local duration_string="${duration_minutes}m ${duration_seconds}s"
      
      log_info "Deployment completed successfully in $duration_string"
      notify_deployment_success "$namespace" "$component" "current" "$duration_string" ""
      return 0
    fi
    
    sleep 10
  done
}

# =============================================================================
# LOG MONITORING
# =============================================================================

monitor_application_logs() {
  local namespace="$1"
  local component="$2"
  local error_patterns="${3:-ERROR|FATAL|Exception|CRITICAL}"
  local warning_patterns="${4:-WARN|WARNING}"
  local max_lines="${5:-100}"
  
  log_info "Monitoring application logs for $component..."
  
  # Get pod names for the component
  local pods=$(oc get pods -n "$namespace" -l app="$component" -o name 2>/dev/null)
  
  if [ -z "$pods" ]; then
    log_warn "No pods found for component $component"
    return 1
  fi
  
  local error_count=0
  local warning_count=0
  
  for pod in $pods; do
    local pod_name=$(echo "$pod" | cut -d'/' -f2)
    log_debug "Checking logs for pod: $pod_name"
    
    # Get recent logs
    local logs=$(oc logs "$pod" -n "$namespace" --tail="$max_lines" 2>/dev/null)
    
    # Count errors and warnings
    local pod_errors=$(echo "$logs" | grep -iE "$error_patterns" | wc -l)
    local pod_warnings=$(echo "$logs" | grep -iE "$warning_patterns" | wc -l)
    
    error_count=$((error_count + pod_errors))
    warning_count=$((warning_count + pod_warnings))
    
    if [ "$pod_errors" -gt 0 ]; then
      log_warn "Found $pod_errors errors in pod $pod_name"
      # Get sample of error messages
      local sample_errors=$(echo "$logs" | grep -iE "$error_patterns" | head -3)
      notify_security_issue "medium" "$component" "Application Errors" "Errors detected in pod $pod_name" "Check application logs"
    fi
  done
  
  log_info "Log monitoring complete: $error_count errors, $warning_count warnings found"
  
  if [ "$error_count" -gt 10 ]; then
    notify_security_issue "high" "$component" "High Error Rate" "Detected $error_count errors across component pods" "Investigate application issues"
    return 1
  fi
  
  return 0
}