#!/bin/bash
# =============================================================================
# Site Monitor — Deployment State Tracker
# =============================================================================
# Polls a target URL to detect deployment state transitions and waits for
# the site to stabilize before returning. Used by the Lighthouse Monitor
# CI job to know when the deploy is complete and auditing can begin.
#
# State machine: BASELINE → DEPLOYING → READY
#   BASELINE:  Site is live (or starting up), waiting for deploy disruption
#   DEPLOYING: Non-200 or maintenance content detected, deploy in progress
#   READY:     Site recovered after deploy, stabilization wait passed
#
# Usage:
#   source openshift/scripts/utils/site-monitor.sh
#   monitor_site_deployment "https://example.com" [poll_interval] [baseline_timeout] [deploy_timeout] [stabilize_wait]
#
# Outputs (via GITHUB_OUTPUT if available):
#   MONITOR_RESULT: BASELINE | DEPLOYING | READY | timeout_deploying
#
# Exit codes:
#   0 — monitoring complete (check MONITOR_RESULT for final state)
#   1 — configuration error
#
# See: .docs/diagrams/build-deployment-flow.md
# =============================================================================

monitor_site_deployment() {
  local target_url="${1:?Usage: monitor_site_deployment <url> [poll_interval] [baseline_timeout] [deploy_timeout] [stabilize_wait]}"
  local poll_interval="${2:-15}"
  local baseline_timeout="${3:-1200}"
  local deploy_timeout="${4:-2400}"
  local stabilize_wait="${5:-15}"

  echo "================================================"
  echo "🔭 DEPLOYMENT MONITOR"
  echo "================================================"
  echo "Target: $target_url"
  echo "Poll: ${poll_interval}s | Baseline timeout: ${baseline_timeout}s | Deploy timeout: ${deploy_timeout}s"
  echo ""

  local STATE="BASELINE"
  local start_time phase_start now elapsed phase_elapsed
  local http_status site_state last_status="" last_site_state=""
  local transition_count=0 baseline_checks=0 timestamp
  local heartbeat_interval=60  # seconds between heartbeat messages
  local last_heartbeat=0

  start_time=$(date +%s)
  phase_start=$start_time

  while true; do
    now=$(date +%s)
    elapsed=$(( now - start_time ))
    phase_elapsed=$(( now - phase_start ))

    # ── Periodic heartbeat (every 60s) so the log doesn't look stuck ──
    if [ $(( now - last_heartbeat )) -ge $heartbeat_interval ]; then
      last_heartbeat=$now
      timestamp=$(date '+%H:%M:%S')
      case "$STATE" in
        BASELINE)  echo "[$timestamp] (+${elapsed}s) ⏳ Waiting for deployment to start... (${phase_elapsed}s/${baseline_timeout}s)" ;;
        DEPLOYING) echo "[$timestamp] (+${elapsed}s) ⏳ Deploy in progress — ${site_state} (HTTP ${http_status:-???}) — ${phase_elapsed}s/${deploy_timeout}s elapsed" ;;
      esac
    fi

    # ── Phase-specific timeout checks ──
    if [ "$STATE" = "BASELINE" ] && [ $phase_elapsed -ge $baseline_timeout ]; then
      echo ""
      echo "⏰ Baseline timeout (${baseline_timeout}s) — deployment not detected"
      echo "   Proceeding with audit against current site"
      break
    fi

    if [ "$STATE" = "DEPLOYING" ] && [ $phase_elapsed -ge $deploy_timeout ]; then
      echo ""
      echo "⏰ Deploy timeout (${deploy_timeout}s) — site has not recovered"
      _monitor_output "MONITOR_RESULT" "timeout_deploying"
      echo "   Skipping audit (site not ready)"
      _monitor_print_summary "$transition_count" "$STATE" "$elapsed" "$baseline_checks"
      return 0
    fi

    # ── Check site status ──
    http_status=$(curl -sSL -o /tmp/lh_site_check.html -w '%{http_code}' \
      --connect-timeout 5 --max-time 10 "$target_url" 2>/dev/null || echo "000")

    # Detect maintenance content (covers OpenShift/Moodle maintenance pages returning 200)
    # Uses specific markers to avoid false positives — Moodle's normal pages contain the
    # word "maintenance" in admin links, so a generic grep would never transition to READY.
    site_state="up"
    if [ "$http_status" = "000" ]; then
      site_state="unreachable"
    elif [ "$http_status" != "200" ]; then
      site_state="down"
    elif grep -qi '<title>Site Maintenance</title>\|Page unavailable due to maintenance\|This site is currently undergoing maintenance\|cli/maintenance.php' /tmp/lh_site_check.html 2>/dev/null; then
      site_state="maintenance"
    fi

    # ── Log state transitions ──
    if [ "$http_status" != "$last_status" ] || [ "$site_state" != "$last_site_state" ]; then
      timestamp=$(date '+%H:%M:%S')
      case "$site_state" in
        up)          echo "[$timestamp] (+${elapsed}s) ✅ Site live: HTTP $http_status" ;;
        maintenance) echo "[$timestamp] (+${elapsed}s) 🔧 Maintenance page detected: HTTP $http_status" ;;
        down)        echo "[$timestamp] (+${elapsed}s) 🔴 Site unavailable: HTTP $http_status" ;;
        unreachable) echo "[$timestamp] (+${elapsed}s) 🔌 Site unreachable: connection failed" ;;
      esac
      last_status="$http_status"
      last_site_state="$site_state"
      transition_count=$((transition_count + 1))
    fi

    # ── State transitions ──
    case "$STATE" in
      BASELINE)
        baseline_checks=$((baseline_checks + 1))
        if [ "$site_state" != "up" ]; then
          STATE="DEPLOYING"
          phase_start=$(date +%s)
          echo "   📡 Deployment detected — entering monitoring phase"
        fi
        ;;
      DEPLOYING)
        if [ "$site_state" = "up" ]; then
          STATE="READY"
          echo "   🎯 Site recovered — deployment appears complete (${elapsed}s total)"
          echo "   ⏳ Stabilization wait (${stabilize_wait}s)..."
          sleep "$stabilize_wait"
          break
        fi
        ;;
    esac

    sleep "$poll_interval"
  done

  _monitor_print_summary "$transition_count" "$STATE" "$elapsed" "$baseline_checks"
  _monitor_output "MONITOR_RESULT" "$STATE"
  return 0
}

# ── Internal helpers ──

_monitor_print_summary() {
  local transition_count="$1" state="$2" elapsed="$3" baseline_checks="$4"
  echo ""
  echo "================================================"
  echo "📊 MONITORING SUMMARY"
  echo "================================================"
  echo "  State transitions: $transition_count"
  echo "  Final state: $state"
  echo "  Total monitoring time: ${elapsed}s"
  echo "  Baseline checks: $baseline_checks"
  echo ""
}

_monitor_output() {
  local key="$1" value="$2"
  if [ -n "$GITHUB_OUTPUT" ]; then
    echo "$key=$value" >> "$GITHUB_OUTPUT"
  fi
}
