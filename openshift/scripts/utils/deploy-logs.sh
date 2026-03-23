#!/bin/bash
# =============================================================================
# Deployment Job Log Capture
# =============================================================================
# Fetches and displays logs from critical OpenShift deployment jobs
# (migrate-build-files, moodle-upgrade). Polls for job completion
# before capturing logs, handling the case where jobs are still running.
#
# Usage:
#   source openshift/scripts/utils/deploy-logs.sh
#   capture_deployment_logs <namespace> <oc_token> <oc_server> [timeout_seconds]
#
# Prerequisites:
#   - oc CLI must be available in PATH (installed by caller)
#   - Valid OpenShift auth token
#
# Outputs:
#   - Logs printed to stdout (visible in CI)
#   - Log files saved to tmp/artifacts/ for artifact upload
#
# See: .docs/diagrams/build-deployment-flow.md
# =============================================================================

capture_deployment_logs() {
  local namespace="${1:?Usage: capture_deployment_logs <namespace> <oc_token> <oc_server> [timeout]}"
  local oc_token="${2:?Missing oc_token}"
  local oc_server="${3:-https://api.silver.devops.gov.bc.ca:6443}"
  local timeout="${4:-120}"

  echo "================================================"
  echo "📋 DEPLOYMENT JOB LOG CAPTURE"
  echo "================================================"
  echo ""

  mkdir -p tmp/artifacts

  # ── Install oc CLI if not present ──
  if ! command -v oc &>/dev/null; then
    echo "Installing oc CLI..."
    curl -sSL --connect-timeout 15 --max-time 60 \
      https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz \
      | tar xz 2>/dev/null
    if [ -f "./oc" ]; then
      sudo mv oc /usr/local/bin/
    else
      echo "⚠️ Failed to download oc CLI — skipping log capture"
      return 0
    fi
  fi
  echo "oc version: $(oc version --client 2>/dev/null | head -1)"

  # ── Login to OpenShift with retry ──
  local login_ok=false
  for attempt in 1 2 3; do
    if oc login --token="$oc_token" \
         --server="$oc_server" \
         --insecure-skip-tls-verify=true \
         --request-timeout=30s 2>&1 | grep -v '^Warning:'; then
      login_ok=true
      break
    fi
    echo "⚠️ oc login attempt $attempt failed — retrying in 10s..."
    sleep 10
  done

  if [ "$login_ok" != "true" ]; then
    echo "⚠️ Could not connect to OpenShift API after 3 attempts — skipping log capture"
    echo "   This is typically a transient network issue. Job logs are still available"
    echo "   via: oc logs -n $namespace -l job-name=<job-name>"
    return 0
  fi

  oc project "$namespace" 2>/dev/null || true

  # ── Capture logs for each deployment job ──
  _capture_job_logs "migrate-build-files" "📂" "$namespace" "$timeout"
  _capture_job_logs "moodle-upgrade" "🔄" "$namespace" "$timeout"

  echo ""
  echo "════════════════════════════════════════════════"
  echo "📋 Job log capture complete"
  echo "════════════════════════════════════════════════"
}

# =============================================================================
# _capture_job_logs — Poll for a job pod and stream its logs
# =============================================================================
_capture_job_logs() {
  local job_name="$1"
  local icon="$2"
  local namespace="$3"
  local timeout="$4"

  echo ""
  echo "────────────────────────────────────────────────"
  echo "$icon $job_name"
  echo "────────────────────────────────────────────────"

  # Poll for the pod to appear (it may not exist yet if deploy is still running)
  local pod_name="" pod_status="" wait_start poll_elapsed
  wait_start=$(date +%s)

  while true; do
    pod_name=$(oc get pods -n "$namespace" --selector=job-name="$job_name" \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

    if [ -n "$pod_name" ]; then
      pod_status=$(oc get pod -n "$namespace" "$pod_name" \
        -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")

      # If pod is completed or failed, we can grab logs immediately
      if [ "$pod_status" = "Succeeded" ] || [ "$pod_status" = "Failed" ]; then
        break
      fi

      # If pod is running, wait for it to finish (follow logs)
      if [ "$pod_status" = "Running" ]; then
        echo "Pod: $pod_name (Status: Running — streaming live logs...)"
        echo ""
        # Stream logs until pod completes (--follow exits when container stops)
        oc logs -n "$namespace" "$pod_name" --follow 2>/dev/null \
          | tee "tmp/artifacts/${job_name}.log" || true
        # Re-check status after follow completes
        pod_status=$(oc get pod -n "$namespace" "$pod_name" \
          -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
        echo ""
        echo "Pod completed with status: $pod_status"
        return 0
      fi
    fi

    # Timeout check
    poll_elapsed=$(( $(date +%s) - wait_start ))
    if [ $poll_elapsed -ge $timeout ]; then
      if [ -n "$pod_name" ]; then
        echo "⏰ Timeout waiting for $job_name pod to complete (status: $pod_status)"
        echo "   Capturing partial logs..."
        oc logs -n "$namespace" "$pod_name" 2>/dev/null \
          | tee "tmp/artifacts/${job_name}.log" || true
      else
        echo "ℹ️ No $job_name pod found after ${timeout}s (job may not run in this deployment)"
      fi
      return 0
    fi

    sleep 10
  done

  # Grab completed/failed pod logs
  echo "Pod: $pod_name (Status: $pod_status)"
  echo ""
  oc logs -n "$namespace" "$pod_name" 2>/dev/null \
    | tee "tmp/artifacts/${job_name}.log" || \
    echo "⚠️ Could not retrieve logs (pod may have been cleaned up)"
}
