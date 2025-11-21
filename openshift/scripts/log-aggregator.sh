#!/bin/bash
# =============================================================================
# LOG AGGREGATOR AND EVENT FORWARDER
# =============================================================================
# Purpose: Aggregates critical events and forwards to external systems
#          Supports both inline piping and separate deployment modes
#
# Usage Modes:
#   1. INLINE (default): Piped from check-pod-logs.sh via process substitution
#      $ exec 1> >(bash log-aggregator.sh pipe)
#
#   2. SEPARATE: Deployed via galera-log-aggregator.yml, follows CronJob logs
#      $ bash log-aggregator.sh follow check-pod-logs namespace
#
#   3. COLLECT: One-time collection from recent CronJob executions
#      $ bash log-aggregator.sh collect check-pod-logs namespace
#
# Event Format (parsed from stdin):
#   CRITICAL_EVENT|timestamp|namespace|event_type|message
#   Example: CRITICAL_EVENT|2025-11-20T10:30:00|950003-dev|GALERA_SPLIT_BRAIN|...
#
# Forwarding Destinations:
#   - RocketChat webhook (if ROCKET_CHAT_WEBHOOK set)
#   - Slack webhook (if SLACK_WEBHOOK set)
#   - Syslog server (if SYSLOG_SERVER set)
#   - OpenShift Events (always, via oc create event)
#
# Configuration:
#   LOG_RETENTION_HOURS=72   - In-memory session retention (not persistent)
#   MAX_LOG_SIZE_MB=50       - Unused (in-memory only, no files)
#
# Related Documentation:
#   - Architecture: See LOG AGGREGATION CONFIGURATION in check-pod-logs.sh
#   - Separate deployment: ../galera-log-aggregator.yml
#   - Webhook setup: ./deploy-health-monitor.sh
# =============================================================================

# Configuration
LOG_RETENTION_HOURS=${LOG_RETENTION_HOURS:-72}  # Keep logs for 3 days
ROCKET_CHAT_WEBHOOK=${ROCKET_CHAT_WEBHOOK:-""}
SLACK_WEBHOOK=${SLACK_WEBHOOK:-""}
SYSLOG_SERVER=${SYSLOG_SERVER:-""}
MAX_LOG_SIZE_MB=${MAX_LOG_SIZE_MB:-50}

# In-memory log storage (for current session)
declare -a EVENT_LOG=()

# Function to parse and extract critical events from stdin
parse_critical_events() {
  while IFS= read -r line; do
    # Look for structured critical events
    if [[ "$line" =~ ^CRITICAL_EVENT\| ]]; then
      EVENT_LOG+=("$line")
      forward_event "$line"
    fi

    # Also forward the original line to stdout for normal logging
    echo "$line"
  done
}

# Function to forward events to external systems
forward_event() {
  local event="$1"
  local timestamp=$(echo "$event" | cut -d'|' -f2)
  local namespace=$(echo "$event" | cut -d'|' -f3)
  local event_type=$(echo "$event" | cut -d'|' -f4)
  local message=$(echo "$event" | cut -d'|' -f5)

  # Format for human readability
  local formatted_message="🚨 **${event_type}** in \`${namespace}\`\n⏰ ${timestamp}\n📝 ${message}"

  # Send to Rocket.Chat if configured
  if [[ -n "$ROCKET_CHAT_WEBHOOK" ]]; then
    send_to_rocketchat "$formatted_message"
  fi

  # Send to Slack if configured
  if [[ -n "$SLACK_WEBHOOK" ]]; then
    send_to_slack "$formatted_message"
  fi

  # Send to syslog if configured
  if [[ -n "$SYSLOG_SERVER" ]]; then
    send_to_syslog "$event"
  fi

  # Log to OpenShift Events (visible in oc get events)
  oc create event --type=Warning --reason="$event_type" \
    --message="$message" --reporting-instance="log-aggregator" \
    --reporting-component="galera-monitor" 2>/dev/null || true
}

# Function to send to Rocket.Chat
send_to_rocketchat() {
  local message="$1"
  curl -s -X POST "$ROCKET_CHAT_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "{\"text\": \"$message\"}" > /dev/null 2>&1 || true
}

# Function to send to Slack
send_to_slack() {
  local message="$1"
  curl -s -X POST "$SLACK_WEBHOOK" \
    -H 'Content-Type: application/json' \
    -d "{\"text\": \"$message\"}" > /dev/null 2>&1 || true
}

# Function to send to syslog
send_to_syslog() {
  local event="$1"
  logger -n "$SYSLOG_SERVER" -t "moodle-galera" "$event" 2>/dev/null || true
}

# Function to create summary report
create_summary_report() {
  local total_events=${#EVENT_LOG[@]}

  if [[ $total_events -eq 0 ]]; then
    return 0
  fi

  local summary="📊 **Galera Monitoring Summary**\n"
  summary+="⏰ Session: $(date)\n"
  summary+="\`\`\`\n"
  summary+="Total critical events: $total_events\n"

  # Count event types
  local split_brain_count=$(printf '%s\n' "${EVENT_LOG[@]}" | grep -c "GALERA_SPLIT_BRAIN_DETECTED" || true)
  local auto_heal_count=$(printf '%s\n' "${EVENT_LOG[@]}" | grep -c "GALERA_AUTO_HEAL_SUCCESS" || true)
  local failed_heal_count=$(printf '%s\n' "${EVENT_LOG[@]}" | grep -c "GALERA_AUTO_HEAL_FAILED" || true)

  summary+="Split-brain events: $split_brain_count\n"
  summary+="Successful auto-heals: $auto_heal_count\n"
  summary+="Failed auto-heals: $failed_heal_count\n"
  summary+="\`\`\`\n"

  # Send summary to configured endpoints
  if [[ -n "$ROCKET_CHAT_WEBHOOK" ]]; then
    send_to_rocketchat "$summary"
  fi

  if [[ -n "$SLACK_WEBHOOK" ]]; then
    send_to_slack "$summary"
  fi
}

# Function to run as a pipe processor
run_as_pipe() {
  # Process stdin and forward events
  parse_critical_events

  # Create summary at the end
  create_summary_report
}

# Function to run as a log collector (reads from OpenShift logs)
run_as_collector() {
  local job_name="${1:-check-pod-logs}"
  local namespace="${2:-$DEPLOY_NAMESPACE}"
  local follow="${3:-false}"

  echo "Collecting logs from CronJob: $job_name in namespace: $namespace"

  if [[ "$follow" == "true" ]]; then
    # Follow logs from the most recent job
    oc logs -n "$namespace" -l job-name="$job_name" -f --tail=100 | parse_critical_events
  else
    # Get logs from recent jobs
    local jobs=$(oc get jobs -n "$namespace" -l job-name="$job_name" --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-3:].metadata.name}')
    for job in $jobs; do
      echo "Processing logs from job: $job"
      oc logs -n "$namespace" job/"$job" | parse_critical_events
    done
    create_summary_report
  fi
}

# Main execution
case "${1:-pipe}" in
  "pipe")
    run_as_pipe
    ;;
  "collect")
    run_as_collector "$2" "$3" "$4"
    ;;
  "follow")
    run_as_collector "$2" "$3" "true"
    ;;
  *)
    echo "Usage: $0 [pipe|collect|follow] [job_name] [namespace]"
    echo "  pipe    - Process stdin and forward critical events (default)"
    echo "  collect - Collect logs from recent CronJob executions"
    echo "  follow  - Follow logs from CronJob in real-time"
    exit 1
    ;;
esac
