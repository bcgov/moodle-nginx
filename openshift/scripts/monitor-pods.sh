#!/bin/bash
# Force UTF-8 locale so emoji/unicode in arrays render correctly in pod logs
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# =============================================================================
# CONTINUOUS POD HEALTH MONITOR
# =============================================================================
# Purpose: Lightweight continuous monitoring wrapper for pod health checks
#          Runs as a long-lived deployment instead of CronJob
#
# Architecture:
#   - Runs in loop with configurable intervals
#   - Calls check-pod-logs.sh utility functions for actual health checks
#   - Tracks consecutive errors per pod for intelligent restart logic
#   - Special handling for Galera cluster with separate check interval
#
# Deployment:
#   - Via pod-health-monitor.yml template
#   - Requires same service account permissions as check-pod-logs.sh
#   - Automatically deployed by ./deploy-health-monitor.sh
#
# Configuration:
#   MONITORING_INTERVAL=60      - Seconds between quick health checks
#   GALERA_CHECK_INTERVAL=300   - Seconds between comprehensive Galera checks
#   ERROR_THRESHOLD=3           - Consecutive errors before pod restart
#
# Related Documentation:
#   - Core health checks: ./check-pod-logs.sh (comprehensive monitoring logic)
#   - Deployment guide: ./deploy-health-monitor.sh
#   - Architecture: ../../docs/galera-monitoring-solution.md
# =============================================================================

# Configuration
MONITORING_INTERVAL=${MONITORING_INTERVAL:-60}
GALERA_CHECK_INTERVAL=${GALERA_CHECK_INTERVAL:-300}  # Check Galera every 5 minutes
ERROR_THRESHOLD=${ERROR_THRESHOLD:-3}  # Number of consecutive errors before restart
MANUAL_MODE=${MANUAL_MODE:-false}  # Override flag - set to 'true' to disable all auto-healing
AUTO_APPLY_GALERA_TIMEOUTS=${AUTO_APPLY_GALERA_TIMEOUTS:-true}  # Auto-apply PT30S timeouts during recovery

# Track consecutive errors per pod
declare -A error_counts

# Track last restart time per selector to prevent restart loops
# During cluster maintenance, node drains cause transient startup errors.
# Without cooldown, the monitor would restart pods that just restarted.
declare -A last_restart_time
declare -A pod_restart_counts       # Per-pod restart counter within window
declare -A pod_restart_window_start # Per-pod window start epoch
POD_MIN_AGE_SECONDS=${POD_MIN_AGE_SECONDS:-120}       # Skip pods younger than this (startup grace)
RESTART_COOLDOWN_SECONDS=${RESTART_COOLDOWN_SECONDS:-300}  # Min time between restarts per service
MAX_POD_RESTARTS=${MAX_POD_RESTARTS:-3}                # Max restarts per pod within window
MAX_POD_RESTART_WINDOW=${MAX_POD_RESTART_WINDOW:-1800} # Window in seconds (30min)

# Initialize logging
echo "Starting continuous pod health monitoring..."
echo "Monitoring interval: ${MONITORING_INTERVAL}s"
echo "Galera check interval: ${GALERA_CHECK_INTERVAL}s"
echo "Error threshold: ${ERROR_THRESHOLD}"
echo "Auto-apply Galera timeouts: ${AUTO_APPLY_GALERA_TIMEOUTS}"

# Manual mode override check
if [[ "${MANUAL_MODE,,}" == "true" ]]; then
  echo ""
  echo "----------------------------------------------------------------"
  echo "MANUAL MODE ENABLED"
  echo "----------------------------------------------------------------"
  echo "All auto-healing actions are DISABLED."
  echo "Pod health monitoring is READ-ONLY - manual intervention in progress."
  echo ""
  echo "To re-enable auto-healing:"
  echo "  oc set env deployment/pod-health-monitor MANUAL_MODE=false -n $DEPLOY_NAMESPACE"
  echo ""
  echo "Galera timeout auto-apply: ${AUTO_APPLY_GALERA_TIMEOUTS}"
  echo "To control PT30S timeout configuration:"
  echo "  oc set env deployment/pod-health-monitor AUTO_APPLY_GALERA_TIMEOUTS=true|false -n $DEPLOY_NAMESPACE"
  echo "----------------------------------------------------------------"
  echo ""
fi

# Universal _utils.sh loader - works in all environments
# Priority: same-dir > /scripts > /usr/local/bin > ./openshift/scripts
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

# Validate required environment
if [[ -z "$DEPLOY_NAMESPACE" ]]; then
  echo "FATAL: DEPLOY_NAMESPACE is not set - cannot monitor pods"
  exit 1
fi

# Authenticate with OpenShift API (same as check-pod-logs.sh)
# Set writable kubeconfig path - container filesystem root is read-only
export KUBECONFIG="/tmp/.kube/config"
mkdir -p "$(dirname "$KUBECONFIG")"

# Check if running in-cluster with service account
if [[ -f "/var/run/secrets/kubernetes.io/serviceaccount/token" && -z "$OPENSHIFT_TOKEN" ]]; then
  echo "INFO: Running in-cluster with service account - configuring oc to use pod SA token"
  SA_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  CLUSTER_SERVER="${OPENSHIFT_SERVER:-https://kubernetes.default.svc}"

  oc login --token="$SA_TOKEN" --server="$CLUSTER_SERVER" --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:"
  oc project "$DEPLOY_NAMESPACE" 2>/dev/null || true
elif [[ -n "$OPENSHIFT_TOKEN" && -n "$OPENSHIFT_SERVER" ]]; then
  echo "INFO: Using provided OPENSHIFT_TOKEN for authentication"
  oc login --token="$OPENSHIFT_TOKEN" --server="$OPENSHIFT_SERVER" --insecure-skip-tls-verify=true 2>&1 | grep -v "^Warning:"
  oc project "$DEPLOY_NAMESPACE" 2>/dev/null || true
else
  echo "WARNING: Neither in-cluster SA token nor OPENSHIFT_TOKEN found - oc commands may fail"
fi

# Validate oc connectivity - fail fast if API is unreachable
if ! oc get namespace "$DEPLOY_NAMESPACE" -o name &>/dev/null; then
  echo "FATAL: Cannot reach OpenShift API or namespace $DEPLOY_NAMESPACE - check credentials"
  exit 1
fi
echo "[OK] OpenShift API connectivity verified for namespace: $DEPLOY_NAMESPACE"

# Suppress repetitive oc CLI warnings (legacy token, insecure TLS) from polluting health check logs
export KUBECTL_WARN_EXTERNAL_UNKNOWN=false
oc() { command oc "$@" 2> >(grep -v "^Warning:" >&2); }

# Unified pod health check function
# $1: selector  $2: error_patterns  $3: restart_enabled (true/false)
# $4: error_threshold (optional, overrides global ERROR_THRESHOLD)
# Appends to global issue_details[] array, increments pods_checked counter,
# and appends to service_summary[] for per-service visibility.
check_pod_health() {
  local selector="$1"
  local error_patterns="$2"
  local restart_enabled="${3:-false}"
  local threshold="${4:-$ERROR_THRESHOLD}"

  local pods_output
  pods_output=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>&1)
  local oc_exit=$?
  local pod_count=0
  local mode_label="observe"
  [[ "$restart_enabled" == "true" ]] && mode_label="restart"

  # Distinguish "no pods" from "oc comm failed" (auth expired, network, etc.)
  if [[ $oc_exit -ne 0 ]]; then
    service_summary+=("  [WARN] $selector - oc query failed (exit $oc_exit) [$mode_label]")
    issue_details+=("  [WARN] oc get pods -l $selector failed - possible API connectivity issue")
    return 1
  fi

  local pods="$pods_output"
  if [[ -z "$pods" ]]; then
    service_summary+=("  [INFO] $selector - no running pods [$mode_label]")
    return 0
  fi

  local issues_found=0

  for pod in $pods; do
    pod_count=$((pod_count + 1))

    # Pod age gate: skip pods that just started (transient startup errors)
    # Bypass for redis-proxy — it cannot self-heal and must restart immediately
    if [[ "$selector" != "app=redis-proxy" ]]; then
      local start_time
      start_time=$(oc get pod "$pod" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.startTime}' 2>/dev/null)
      if [[ -n "$start_time" ]]; then
        local start_epoch
        start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
        local age=$(( $(date +%s) - start_epoch ))
        if [[ $age -lt $POD_MIN_AGE_SECONDS ]]; then
          issue_details+=("  [SKIP] $pod - too young (${age}s < ${POD_MIN_AGE_SECONDS}s startup grace)")
          pods_checked=$((pods_checked + 1))
          continue
        fi
      fi
    fi

    # Check recent logs for error patterns.
    # redis-proxy: check ALL logs (no --since). Proxy logs are tiny (< 20 lines total)
    # and errors are persistent state (stale connection from startup), not time-bounded.
    # Other services: use --since window to avoid reacting to old resolved errors.
    local recent_logs
    if [[ "$selector" == "app=redis-proxy" ]]; then
      recent_logs=$(oc logs "$pod" --tail=50 2>/dev/null)
    else
      local since_seconds=$((MONITORING_INTERVAL * 2 + 30))
      recent_logs=$(oc logs "$pod" --tail=50 --since="${since_seconds}s" 2>/dev/null)
    fi

    if [[ -z "$recent_logs" ]]; then
      pods_checked=$((pods_checked + 1))
      continue
    fi

    IFS=',' read -ra patterns <<< "$error_patterns"
    local pod_has_errors=false

    for pattern in "${patterns[@]}"; do
      pattern=$(echo "$pattern" | xargs)
      if [[ -n "$pattern" && "$recent_logs" == *"$pattern"* ]]; then
        error_counts["$pod"]=$((${error_counts["$pod"]:-0} + 1))
        pod_has_errors=true

        local consecutive=${error_counts["$pod"]}
        local mode="observe"
        [[ "$restart_enabled" == "true" ]] && mode="restart-eligible"

        issue_details+=("  [WARN] $pod [$mode] - pattern '$pattern' (consecutive: $consecutive/$threshold)")
        break
      fi
    done

    if [[ "$pod_has_errors" == "false" ]]; then
      error_counts["$pod"]=0
    fi

    pods_checked=$((pods_checked + 1))

    # Restart only for restart-eligible pods at error threshold
    if [[ "$restart_enabled" == "true" && ${error_counts["$pod"]:-0} -ge $threshold ]]; then
      if [[ "${MANUAL_MODE,,}" == "true" ]]; then
        issue_details+=("  - [MANUAL MODE] Would restart $pod - $threshold consecutive errors (auto-healing disabled)")
        continue
      fi

      # Cooldown: prevent restart loops during cluster maintenance
      # Bypass for redis-proxy — it cannot self-heal, immediate restart required
      if [[ "$selector" != "app=redis-proxy" ]]; then
        local last_restart="${last_restart_time[$selector]:-0}"
        local since_last=$(( $(date +%s) - last_restart ))
        if [[ $since_last -lt $RESTART_COOLDOWN_SECONDS ]]; then
          local remaining=$(( RESTART_COOLDOWN_SECONDS - since_last ))
          issue_details+=("  [COOLDOWN] $pod - restart suppressed (${remaining}s remaining for $selector)")
          continue
        fi
      fi

      # Per-pod restart cap: prevent infinite restart loops when restarts don't fix the issue.
      # If a pod has been restarted MAX_POD_RESTARTS times within MAX_POD_RESTART_WINDOW,
      # stop restarting it and alert instead.
      local _now
      _now=$(date +%s)
      local window_start="${pod_restart_window_start[$pod]:-0}"
      if [[ $(( _now - window_start )) -gt $MAX_POD_RESTART_WINDOW ]]; then
        pod_restart_counts["$pod"]=0
        pod_restart_window_start["$pod"]=$_now
      fi
      local pod_restarts="${pod_restart_counts[$pod]:-0}"
      if [[ $pod_restarts -ge $MAX_POD_RESTARTS ]]; then
        issue_details+=("  [CAPPED] $pod - restart suppressed ($pod_restarts/$MAX_POD_RESTARTS restarts in $(( (_now - window_start) / 60 ))min window)")
        issue_details+=("     Restarts are not fixing $pod — manual investigation required")
        if [[ $pod_restarts -eq $MAX_POD_RESTARTS ]]; then
          send_notification "POD_RESTART_CAPPED" "Pod Restart Cap Reached" "Pod $pod has been restarted $MAX_POD_RESTARTS times in ${MAX_POD_RESTART_WINDOW}s without recovery. Stopping automatic restarts — manual investigation required. Selector: $selector" "error" "$DEPLOY_NAMESPACE"
        fi
        continue
      fi

      issue_details+=("  [ACTION] RESTARTING $pod - $threshold consecutive errors reached")

      if oc delete pod "$pod" --wait=false; then
        send_notification "POD_RESTART_THRESHOLD" "Pod Restarted - Error Threshold" "Pod $pod restarted after $threshold consecutive errors. Selector: $selector" "warning" "$DEPLOY_NAMESPACE"
        error_counts["$pod"]=0
        pod_restart_counts["$pod"]=$(( ${pod_restart_counts[$pod]:-0} + 1 ))
        last_restart_time["$selector"]=$(date +%s)
        issues_found=$((issues_found + 1))

        # Post-restart verification - wait briefly, then check if replacement pod starts
        issue_details+=("  [WAIT] Waiting 15s for replacement pod...")
        sleep 15
        local new_pods=$(oc get pods -l "$selector" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
        if [[ -n "$new_pods" ]]; then
          issue_details+=("  [OK] Replacement pod(s) running: $new_pods")
        else
          local pending_pods=$(oc get pods -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null)
          issue_details+=("  [ERROR] No running replacement yet - pod status: ${pending_pods:-unknown}")
          issue_details+=("     Check: oc get pods -l $selector -n $DEPLOY_NAMESPACE")
        fi
      else
        issue_details+=("  - Failed to delete $pod - oc delete returned non-zero")
        issue_details+=("     Check: oc describe pod $pod -n $DEPLOY_NAMESPACE")
      fi
    fi
  done

  # Per-service summary line for visibility
  if [[ $issues_found -gt 0 ]]; then
    service_summary+=("  [ALERT] $selector - $pod_count pod(s), $issues_found issue(s) [$mode_label]")
  else
    service_summary+=("  [OK] $selector - $pod_count pod(s) healthy [$mode_label]")
  fi

  return $issues_found
}

# Main monitoring loop
last_galera_check=0
last_status_report=0
check_cycle=0
STATUS_REPORT_INTERVAL=${STATUS_REPORT_INTERVAL:-600}  # Status summary every 10 minutes

# Send startup notification
send_notification "MONITORING_START" "Pod Health Monitor Started" "Continuous monitoring active with ${MONITORING_INTERVAL}s intervals. Galera checks every ${GALERA_CHECK_INTERVAL}s." "white_check_mark" "$DEPLOY_NAMESPACE"

while true; do
  current_time=$(date +%s)

  # Deployments eligible for threshold-based restart
  # Format: selector -> "error_patterns"
  declare -A RESTART_DEPLOYMENTS
  RESTART_DEPLOYMENTS=(
    ["deployment=php"]="error,critical"
    ["app=redis-proxy"]="err:,error"
  )

  # Per-service error threshold overrides (default: ERROR_THRESHOLD)
  # redis-proxy: threshold=1 — cannot self-heal from connection errors,
  # the only fix is a pod restart.
  declare -A RESTART_THRESHOLDS
  RESTART_THRESHOLDS=(
    ["app=redis-proxy"]=1
  )

  # Deployments to observe only (log errors, no restart)
  # - cron: transient DB/Redis errors during startup, auto-recovers
  # - web: nginx auto-recovers, restart won't help
  # - mariadb-galera: handled by dedicated Galera check at GALERA_CHECK_INTERVAL
  # - redis-node: NOT monitored here. "lost" patterns are normal RDB channel closures
  #   after successful replica sync (not errors). Sentinel handles all failover/reconnection
  #   automatically. Actual Redis issues surface through redis-proxy err: patterns instead.
  declare -A OBSERVE_DEPLOYMENTS
  OBSERVE_DEPLOYMENTS=(
    ["app=cron"]="error,critical"
    ["deployment=web"]="emerg,crit"
  )

  # Perform health checks - restart-eligible services
  total_issues=0
  degraded_mode=0
  pods_checked=0
  issue_details=()
  service_summary=()
  for selector in "${!RESTART_DEPLOYMENTS[@]}"; do
    svc_threshold="${RESTART_THRESHOLDS[$selector]:-$ERROR_THRESHOLD}"
    check_pod_health "$selector" "${RESTART_DEPLOYMENTS[$selector]}" "true" "$svc_threshold"
    total_issues=$((total_issues + $?))
  done

  # Observe-only services (log errors, never restart)
  for selector in "${!OBSERVE_DEPLOYMENTS[@]}"; do
    check_pod_health "$selector" "${OBSERVE_DEPLOYMENTS[$selector]}" "false"
    total_issues=$((total_issues + $?))
  done

  check_cycle=$((check_cycle + 1))

  # Comprehensive infrastructure checks at longer interval (Galera + Redis Proxy)
  if [[ $((current_time - last_galera_check)) -ge $GALERA_CHECK_INTERVAL ]]; then

    # -- Redis Proxy connectivity check --
    # Log-based checks miss stale proxy connections (errors are sparse and the proxy
    # appears Running/Ready to Kubernetes while silently failing intermittently).
    # Test actual Redis PING through each proxy pod to detect broken tunnels.
    proxy_pods=$(oc get pods -l app=redis-proxy --field-selector=status.phase=Running -n "$DEPLOY_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>&1)
    proxy_oc_exit=$?
    if [[ $proxy_oc_exit -ne 0 ]]; then
      service_summary+=("  [WARN] redis-proxy - oc query failed (exit $proxy_oc_exit)")
      issue_details+=("  [WARN] redis-proxy connectivity check skipped - oc command failed")
    elif [[ -n "$proxy_pods" ]]; then
      proxy_healthy=0
      proxy_total=0
      proxy_stale=()
      for proxy_pod in $proxy_pods; do
        proxy_total=$((proxy_total + 1))
        restarts=$(oc get pod "$proxy_pod" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)
        restarts=${restarts:-0}

        # Active connectivity test: PING through the proxy's Redis tunnel
        # redis-cli is available in the proxy container (redis-tools installed)
        ping_result=$(oc exec "$proxy_pod" -n "$DEPLOY_NAMESPACE" -- \
          redis-cli -h localhost -p 6379 PING 2>/dev/null || echo "")

        if [[ "$ping_result" == *"PONG"* ]]; then
          proxy_healthy=$((proxy_healthy + 1))
        else
          # Check logs for recent errors as additional context
          proxy_errors=$(oc logs "$proxy_pod" -n "$DEPLOY_NAMESPACE" --tail=20 2>/dev/null | grep -i "err:\|error\|cannot connect\|refused\|timeout" | tail -3)
          proxy_stale+=("$proxy_pod")
          issue_details+=("  [ALERT] redis-proxy $proxy_pod - PING failed (stale connection, restarts: $restarts)")
          if [[ -n "$proxy_errors" ]]; then
            while IFS= read -r line; do
              issue_details+=("       $line")
            done <<< "$proxy_errors"
          fi

          # Restart the broken proxy immediately
          if [[ "${MANUAL_MODE,,}" != "true" ]]; then
            issue_details+=("  [ACTION] RESTARTING $proxy_pod - stale Redis tunnel detected via PING")
            if oc delete pod "$proxy_pod" -n "$DEPLOY_NAMESPACE" --wait=false 2>/dev/null; then
              send_notification "REDIS_PROXY_STALE" "Redis Proxy Stale Connection" \
                "Restarted $proxy_pod: Redis PING through tunnel failed (stale connection after cluster changes). Restarts: $restarts" \
                "warning" "$DEPLOY_NAMESPACE"
            fi
          else
            issue_details+=("  [MANUAL MODE] Would restart $proxy_pod - stale Redis tunnel")
          fi
        fi
      done

      if [[ ${#proxy_stale[@]} -gt 0 ]]; then
        service_summary+=("  [ALERT] redis-proxy - ${#proxy_stale[@]}/$proxy_total stale (PING failed)")
        total_issues=$((total_issues + ${#proxy_stale[@]}))
      else
        service_summary+=("  [OK] redis-proxy - $proxy_total/$proxy_total connectivity verified")
      fi
    else
      service_summary+=("  [INFO] redis-proxy - no running pods")
    fi

    # -- Cross-service network connectivity probe --
    # Tests actual pod-to-pod TCP paths between key services.
    # OVN migration or SDN issues cause intermittent pod connectivity drops that
    # Kubernetes health checks miss (pods stay Running/Ready while connections fail).
    # This probe provides timestamped evidence for cluster incident reports.
    #
    # Latency thresholds (measured inside the pod to exclude oc exec overhead):
    #   < WARN threshold  : healthy
    #   WARN - CRITICAL   : degraded — network is slow, timeouts likely soon
    #   > CRITICAL        : near-failure — connections may drop under load
    #   TCP connect fail  : broken path
    NET_PROBE_WARN_MS=${NET_PROBE_WARN_MS:-100}       # >100ms = degraded
    NET_PROBE_CRITICAL_MS=${NET_PROBE_CRITICAL_MS:-500}  # >500ms = near-failure

    # ── Deployment detection: suppress noisy alerts during rollouts ──────────
    # When pods are rolling, network failures are expected and not actionable.
    # Also suppress for 10 minutes after a rollout completes (pod warmup).
    deployment_in_progress=false
    DEPLOY_COOLDOWN_FILE="/tmp/logs/last-deployment-seen.ts"
    DEPLOY_COOLDOWN_SECONDS=${DEPLOY_COOLDOWN_SECONDS:-600}  # 10 minutes

    for deploy_name in php moodle-cron web redis-proxy; do
      rollout_status=$(oc rollout status deployment/"$deploy_name" -n "$DEPLOY_NAMESPACE" --timeout=1s 2>&1) || true
      if echo "$rollout_status" | grep -qiE "waiting|progressing|not found"; then
        deployment_in_progress=true
        # Record that we saw a deployment in progress (for cooldown after it completes)
        date +%s > "$DEPLOY_COOLDOWN_FILE"
        echo "$(date): 🚧 Deployment '$deploy_name' is rolling — suppressing network probe alerts"
        break
      fi
    done

    # Check cooldown: if deployment recently completed, still suppress
    if [[ "$deployment_in_progress" == "false" && -f "$DEPLOY_COOLDOWN_FILE" ]]; then
      last_deploy_ts=$(cat "$DEPLOY_COOLDOWN_FILE" 2>/dev/null || echo "0")
      now_ts=$(date +%s)
      elapsed=$(( now_ts - last_deploy_ts ))
      if [[ $elapsed -lt $DEPLOY_COOLDOWN_SECONDS ]]; then
        deployment_in_progress=true
        remaining=$(( DEPLOY_COOLDOWN_SECONDS - elapsed ))
        echo "$(date): 🚧 Deployment completed ${elapsed}s ago — cooldown active (${remaining}s remaining)"
      else
        # Cooldown expired, clean up
        rm -f "$DEPLOY_COOLDOWN_FILE"
      fi
    fi

    echo "$(date): 🌐 Running cross-service network connectivity probe..."
    echo "$(date):    Latency thresholds: warn=${NET_PROBE_WARN_MS}ms, critical=${NET_PROBE_CRITICAL_MS}ms"
    NET_PROBE_LOG="/tmp/logs/network-probe.log"
    mkdir -p /tmp/logs

    net_probe_failures=0
    net_probe_slow=0
    net_probe_tests=0
    net_probe_details=()

    # Define critical network paths to test: source_selector|source_label|target_host|target_port|test_type
    # These are the paths that, when broken, cause our observed failures:
    #   PHP → MariaDB (Galera): Moodle DB queries
    #   PHP → Redis (via proxy): Session locks, caching
    #   Galera → Galera: Cluster replication (wsrep)
    NET_PATHS=(
      "deployment=php|php→mariadb|mariadb-galera|3306|tcp"
      "deployment=php|php→redis-proxy|redis-proxy|6379|tcp"
    )

    # Add Galera inter-node paths if cluster has multiple nodes
    if [[ -n "$galera_running_pods" ]]; then
      galera_pod_array=($galera_running_pods)
      if [[ ${#galera_pod_array[@]} -gt 1 ]]; then
        # Test from first node to the galera headless service (covers wsrep/IST/SST)
        NET_PATHS+=("app.kubernetes.io/name=mariadb-galera|galera→galera-svc|mariadb-galera-headless|4567|tcp")
      fi
    fi

    for net_path in "${NET_PATHS[@]}"; do
      IFS='|' read -r src_selector src_label target_host target_port test_type <<< "$net_path"

      # Pick the first running pod matching the source selector
      src_pod=$(oc get pods -l "$src_selector" --field-selector=status.phase=Running -n "$DEPLOY_NAMESPACE" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

      if [[ -z "$src_pod" ]]; then
        net_probe_details+=("  [SKIP] $src_label - no source pod for $src_selector")
        continue
      fi

      net_probe_tests=$((net_probe_tests + 1))

      # TCP connectivity test — choose method based on what the container has.
      # PHP pods: use php fsockopen (avoids Debian bash /dev/tcp limitation)
      # MariaDB pods: use bash /dev/tcp (RHEL bash supports it)
      # Latency is measured inside the container for accurate pod-to-pod timing.
      if [[ "$src_selector" == *"php"* ]]; then
        # PHP-FPM pods — use php CLI directly (no sh wrapper, no quoting issues)
        probe_output=$(oc exec "$src_pod" -n "$DEPLOY_NAMESPACE" -- \
          php -r "\$s=microtime(true);\$c=@fsockopen('${target_host}',${target_port},\$e,\$m,5);if(\$c){fclose(\$c);printf('OK %d',round((microtime(true)-\$s)*1000));}else{echo 'FAIL 0';}" \
          2>/dev/null || echo "EXEC_FAIL 0")
      else
        # MariaDB/RHEL pods — bash /dev/tcp works here
        probe_output=$(oc exec "$src_pod" -n "$DEPLOY_NAMESPACE" -- \
          bash -c "S=\$(date +%s%N);if timeout 5 bash -c 'echo >/dev/tcp/${target_host}/${target_port}' 2>/dev/null;then E=\$(date +%s%N);echo \"OK \$(((E-S)/1000000))\";else echo 'FAIL 0';fi" \
          2>/dev/null || echo "EXEC_FAIL 0")
      fi

      probe_status="${probe_output%% *}"
      latency_ms="${probe_output##* }"
      [[ ! "$latency_ms" =~ ^[0-9]+$ ]] && latency_ms="?"

      if [[ "$probe_status" == "OK" ]]; then
        # Apply latency thresholds
        if [[ "$latency_ms" != "?" && "$latency_ms" -ge "$NET_PROBE_CRITICAL_MS" ]]; then
          net_probe_slow=$((net_probe_slow + 1))
          net_probe_details+=("  [SLOW] $src_label ($src_pod → $target_host:$target_port) ${latency_ms}ms ⚠️  CRITICAL (>${NET_PROBE_CRITICAL_MS}ms)")
          issue_details+=("  [NETWORK] $src_label SLOW: ${latency_ms}ms (critical >${NET_PROBE_CRITICAL_MS}ms) — timeouts likely")
          echo "$(date '+%Y-%m-%d %H:%M:%S')|SLOW_CRITICAL|$src_label|$src_pod|$target_host:$target_port|${latency_ms}ms" >> "$NET_PROBE_LOG"
        elif [[ "$latency_ms" != "?" && "$latency_ms" -ge "$NET_PROBE_WARN_MS" ]]; then
          net_probe_slow=$((net_probe_slow + 1))
          net_probe_details+=("  [WARN] $src_label ($src_pod → $target_host:$target_port) ${latency_ms}ms (>${NET_PROBE_WARN_MS}ms)")
          issue_details+=("  [NETWORK] $src_label degraded: ${latency_ms}ms (warn >${NET_PROBE_WARN_MS}ms)")
          echo "$(date '+%Y-%m-%d %H:%M:%S')|SLOW_WARN|$src_label|$src_pod|$target_host:$target_port|${latency_ms}ms" >> "$NET_PROBE_LOG"
        else
          net_probe_details+=("  [OK] $src_label ($src_pod → $target_host:$target_port) ${latency_ms}ms")
        fi
      else
        net_probe_failures=$((net_probe_failures + 1))
        net_probe_details+=("  [FAIL] $src_label ($src_pod → $target_host:$target_port) - TCP connect failed after 5s")
        issue_details+=("  [NETWORK] $src_label FAILED: $src_pod cannot reach $target_host:$target_port")

        # Log to persistent file for incident evidence
        echo "$(date '+%Y-%m-%d %H:%M:%S')|FAIL|$src_label|$src_pod|$target_host:$target_port" >> "$NET_PROBE_LOG"
      fi
    done

    # Summary
    if [[ $net_probe_failures -gt 0 ]]; then
      echo "$(date): ❌ Network probe: $net_probe_failures/$net_probe_tests path(s) FAILED"
      for detail in "${net_probe_details[@]}"; do echo "$detail"; done
      service_summary+=("  [ALERT] network - $net_probe_failures/$net_probe_tests path(s) failed")
      total_issues=$((total_issues + net_probe_failures))

      if [[ "$deployment_in_progress" == "true" ]]; then
        echo "$(date): 🚧 Suppressing RocketChat alert — deployment in progress (failures expected)"
        echo "$(date '+%Y-%m-%d %H:%M:%S')|SUPPRESSED|deployment_in_progress|$net_probe_failures/$net_probe_tests paths failed" >> "$NET_PROBE_LOG"
      else
        send_notification "NETWORK_PROBE_FAILURE" "Pod Network Connectivity Issue" \
          "$net_probe_failures/$net_probe_tests cross-service network paths failed in $DEPLOY_NAMESPACE. Possible OVN/SDN issue. Check network-probe.log for history." \
          "error" "$DEPLOY_NAMESPACE"
      fi

      # Log failure batch to persistent file
      echo "$(date '+%Y-%m-%d %H:%M:%S')|SUMMARY|$net_probe_failures/$net_probe_tests paths failed" >> "$NET_PROBE_LOG"
    elif [[ $net_probe_slow -gt 0 ]]; then
      echo "$(date): ⚠️  Network probe: $net_probe_slow/$net_probe_tests path(s) SLOW (all connected)"
      for detail in "${net_probe_details[@]}"; do echo "$detail"; done
      service_summary+=("  [WARN] network - $net_probe_slow/$net_probe_tests path(s) slow, $net_probe_tests/$net_probe_tests connected")
      total_issues=$((total_issues + 1))

      if [[ "$deployment_in_progress" == "true" ]]; then
        echo "$(date): 🚧 Suppressing latency alert — deployment in progress"
      else
        send_notification "NETWORK_PROBE_SLOW" "Pod Network Latency Degraded" \
          "$net_probe_slow/$net_probe_tests network paths have elevated latency (>${NET_PROBE_WARN_MS}ms) in $DEPLOY_NAMESPACE. Possible OVN/SDN degradation. Timeouts may occur under load." \
          "warning" "$DEPLOY_NAMESPACE"
      fi

      echo "$(date '+%Y-%m-%d %H:%M:%S')|SUMMARY|$net_probe_slow/$net_probe_tests paths slow" >> "$NET_PROBE_LOG"
    else
      echo "$(date): ✅ Network probe: all $net_probe_tests path(s) OK"
      for detail in "${net_probe_details[@]}"; do echo "$detail"; done
      service_summary+=("  [OK] network - $net_probe_tests/$net_probe_tests paths verified")

      # Log successful probe periodically (every ~10th check) for baseline evidence
      if [[ $((check_cycle % 10)) -eq 0 ]]; then
        echo "$(date '+%Y-%m-%d %H:%M:%S')|OK|all $net_probe_tests paths|baseline" >> "$NET_PROBE_LOG"
      fi
    fi

    # -- Galera health check --
    echo "$(date): Performing comprehensive Galera health check..."

    # Auto-detect expected cluster size from StatefulSet spec
    galera_expected_size=""
    if oc get statefulset mariadb-galera -n "$DEPLOY_NAMESPACE" &> /dev/null; then
      galera_expected_size=$(oc get statefulset mariadb-galera -n "$DEPLOY_NAMESPACE" -o jsonpath='{.spec.replicas}')
    fi

    # -- Pre-health-check remediation --
    # Fix known issues BEFORE the health verdict so the final status reflects reality.
    # wsrep can report Synced/Primary while nodes are in read_only mode or while
    # stale bootstrap env vars persist — both cause Moodle errors.
    if [[ -n "$galera_expected_size" && "$galera_expected_size" -gt 0 ]]; then
      galera_running_pods=$(oc get pods -l app.kubernetes.io/name=mariadb-galera --field-selector=status.phase=Running -n "$DEPLOY_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

      if [[ -n "$galera_running_pods" ]]; then
        # --- READ-ONLY MODE CHECK ---
        echo "$(date): 🔒 Checking for read-only Galera nodes..."
        read_only_fixed=0
        read_only_count=0

        for g_pod in $galera_running_pods; do
          ro_status=$(oc exec "$g_pod" -n "$DEPLOY_NAMESPACE" -c mariadb-galera -- bash -c \
            'PASS=$(cat /opt/bitnami/mariadb/secrets/mariadb-password 2>/dev/null | tr -d "\n\r"); mysql -u $(printenv MARIADB_USER) --password="$PASS" -sN -e "SELECT @@read_only;" 2>/dev/null' 2>/dev/null || echo "UNKNOWN")

          read_only_count=$((read_only_count + 1))
          if [[ "$ro_status" == "1" ]]; then
            echo "$(date): ⚠️  $g_pod: read_only=ON — Moodle cannot write to this node"

            if [[ "${MANUAL_MODE,,}" == "true" ]]; then
              echo "$(date): [MANUAL MODE] Would run SET GLOBAL read_only=OFF on $g_pod"
            else
              oc exec "$g_pod" -n "$DEPLOY_NAMESPACE" -c mariadb-galera -- bash -c \
                'PASS=$(cat /opt/bitnami/mariadb/secrets/mariadb-root-password 2>/dev/null | tr -d "\n\r"); mysql -u root --password="$PASS" -e "SET GLOBAL read_only=OFF;" 2>/dev/null' 2>/dev/null

              if [[ $? -eq 0 ]]; then
                echo "$(date): ✅ Fixed: SET GLOBAL read_only=OFF on $g_pod"
                read_only_fixed=$((read_only_fixed + 1))
              else
                echo "$(date): ❌ Failed to disable read_only on $g_pod"
                issue_details+=("  [ERROR] Failed to disable read_only on $g_pod")
              fi
            fi
          elif [[ "$ro_status" == "UNKNOWN" ]]; then
            echo "$(date): ⚠️  $g_pod: could not query read_only status"
          fi
        done

        if [[ $read_only_fixed -gt 0 ]]; then
          send_notification "GALERA_READONLY_FIXED" "Galera Read-Only Nodes Fixed" \
            "Disabled read_only on $read_only_fixed node(s) in $DEPLOY_NAMESPACE. Nodes were left in read-only state after bootstrap recovery or restore." \
            "healing" "$DEPLOY_NAMESPACE"
          service_summary+=("  [HEALED] mariadb-galera - $read_only_fixed read-only node(s) fixed")
        else
          echo "$(date): ✅ All $read_only_count node(s) are read-write"
        fi

        # --- STALE BOOTSTRAP ENV VAR CHECK ---
        echo "$(date): 🔧 Checking for stale bootstrap environment variables..."
        bootstrap_val=$(oc get statefulset mariadb-galera -n "$DEPLOY_NAMESPACE" \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MARIADB_GALERA_CLUSTER_BOOTSTRAP")].value}' 2>/dev/null || echo "")

        if [[ "$bootstrap_val" == "yes" ]]; then
          echo "$(date): ⚠️  MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes still set on StatefulSet!"

          if [[ "${MANUAL_MODE,,}" == "true" ]]; then
            echo "$(date): [MANUAL MODE] Would remove bootstrap env vars from StatefulSet"
          else
            echo "$(date): [ACTION] Removing stale bootstrap env vars..."
            oc set env statefulset/mariadb-galera -n "$DEPLOY_NAMESPACE" \
              MARIADB_GALERA_CLUSTER_BOOTSTRAP- \
              MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP- \
              MARIADB_GALERA_CLUSTER_ADDRESS- 2>/dev/null

            if [[ $? -eq 0 ]]; then
              echo "$(date): ✅ Removed stale bootstrap env vars from StatefulSet"
              send_notification "GALERA_BOOTSTRAP_VARS_CLEANED" "Stale Bootstrap Env Vars Removed" \
                "Removed MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes and related vars from StatefulSet in $DEPLOY_NAMESPACE." \
                "healing" "$DEPLOY_NAMESPACE"
            else
              echo "$(date): ❌ Failed to remove bootstrap env vars"
              issue_details+=("  [ERROR] Failed to remove stale bootstrap env vars")
            fi
          fi
        else
          echo "$(date): ✅ No stale bootstrap env vars found"
        fi

        # --- MOODLE DATABASE CONNECTIVITY PROBE ---
        # Verify that Moodle's DB credentials can actually reach the database and
        # that expected tables exist. Catches credential mismatches, empty databases,
        # or wrong database names that wsrep health checks cannot detect.
        echo "$(date): 🔍 Probing Moodle database connectivity..."
        moodle_db_ok=false
        probe_pod="${galera_running_pods%% *}"  # Use first running pod

        # Get Moodle's DB credentials from the same secret Moodle uses
        # Secret keys: database-name, database-user, database-password (not DB_NAME etc.)
        moodle_db_name=$(oc get secret moodle-secrets -n "$DEPLOY_NAMESPACE" -o jsonpath='{.data.database-name}' 2>/dev/null | base64 -d 2>/dev/null)
        moodle_db_user=$(oc get secret moodle-secrets -n "$DEPLOY_NAMESPACE" -o jsonpath='{.data.database-user}' 2>/dev/null | base64 -d 2>/dev/null)
        moodle_db_pass=$(oc get secret moodle-secrets -n "$DEPLOY_NAMESPACE" -o jsonpath='{.data.database-password}' 2>/dev/null | base64 -d 2>/dev/null)

        if [[ -z "$moodle_db_name" || -z "$moodle_db_user" ]]; then
          echo "$(date): ⚠️  Could not read moodle-secrets — skipping Moodle DB probe"
        else
          # Test 1: Can Moodle's user connect and select the database?
          probe_result=$(oc exec "$probe_pod" -n "$DEPLOY_NAMESPACE" -c mariadb-galera -- bash -c \
            "mysql -u '${moodle_db_user}' --password='${moodle_db_pass}' -sN -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema=\"${moodle_db_name}\";' 2>&1" 2>/dev/null || echo "CONNECT_FAILED")

          if [[ "$probe_result" == "CONNECT_FAILED" || "$probe_result" == *"ERROR"* || "$probe_result" == *"Access denied"* ]]; then
            echo "$(date): ❌ MOODLE DB PROBE FAILED: Moodle user '${moodle_db_user}' cannot connect to database '${moodle_db_name}'"
            echo "$(date):    Result: $probe_result"
            issue_details+=("  [CRITICAL] Moodle DB connectivity failed: user='${moodle_db_user}', db='${moodle_db_name}', error: $probe_result")
            total_issues=$((total_issues + 5))
            send_notification "MOODLE_DB_CONNECT_FAILED" "Moodle Database Connection Failed" \
              "Moodle user '${moodle_db_user}' cannot connect to database '${moodle_db_name}' on pod ${probe_pod}. Error: ${probe_result}" \
              "error" "$DEPLOY_NAMESPACE"
          elif [[ "$probe_result" =~ ^[0-9]+$ ]]; then
            if [[ "$probe_result" -eq 0 ]]; then
              echo "$(date): ❌ MOODLE DB PROBE: Database '${moodle_db_name}' exists but has 0 tables!"
              echo "$(date):    This means the restore may have failed or restored to the wrong database."
              issue_details+=("  [CRITICAL] Moodle database '${moodle_db_name}' is empty (0 tables)")
              total_issues=$((total_issues + 5))
              send_notification "MOODLE_DB_EMPTY" "Moodle Database Empty" \
                "Database '${moodle_db_name}' has 0 tables in $DEPLOY_NAMESPACE. Backup restore may have failed." \
                "error" "$DEPLOY_NAMESPACE"
            elif [[ "$probe_result" -lt 100 ]]; then
              echo "$(date): ⚠️  MOODLE DB PROBE: Database '${moodle_db_name}' has only $probe_result tables (expected 400+)"
              issue_details+=("  [WARN] Moodle database '${moodle_db_name}' has only $probe_result tables (expected 400+)")
            else
              echo "$(date): ✅ Moodle DB probe OK: user='${moodle_db_user}', db='${moodle_db_name}', tables=$probe_result"
              moodle_db_ok=true
            fi
          else
            echo "$(date): ⚠️  MOODLE DB PROBE: unexpected result: $probe_result"
            issue_details+=("  [WARN] Moodle DB probe unexpected result: $probe_result")
          fi
        fi
      fi
    fi

    if [[ -n "$galera_expected_size" ]]; then
      # Under-scaled detection: compare live replicas against sizing CSV target.
      # Catches half-completed auto-heal that left the cluster at fewer replicas
      # than the environment target (e.g., 1/5 after a failed recovery).
      galera_sizing_target=""
      if command -v get_sizing_replicas &>/dev/null; then
        galera_sizing_target=$(get_sizing_replicas "mariadb-galera" "$DEPLOY_NAMESPACE" 2>/dev/null)
      fi
      if [[ -n "$galera_sizing_target" && "$galera_sizing_target" =~ ^[0-9]+$ \
            && "$galera_expected_size" =~ ^[0-9]+$ \
            && "$galera_expected_size" -lt "$galera_sizing_target" \
            && "$galera_expected_size" -gt 0 ]]; then
        echo "$(date): [WARN] Under-scaled: StatefulSet replicas=$galera_expected_size, sizing target=$galera_sizing_target"

        if [[ "${MANUAL_MODE,,}" == "true" ]]; then
          echo "$(date): [MANUAL MODE] Under-scaled cluster detected but manual mode is active"
          service_summary+=("  [WARN] mariadb-galera - under-scaled ($galera_expected_size/$galera_sizing_target replicas, MANUAL MODE)")
          send_notification "GALERA_UNDERSCALED" "Galera Under-Scaled (Manual Mode)" \
            "StatefulSet has $galera_expected_size replicas but sizing target is $galera_sizing_target. Manual mode active — not auto-healing." \
            "warning" "$DEPLOY_NAMESPACE"
          # Still run health check in observe mode
          check_and_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE" "$galera_expected_size" false
          galera_status=$?
        else
          # Progressive escalation: track consecutive under-scaled detections
          GALERA_UNDERSCALED_COUNT=${GALERA_UNDERSCALED_COUNT:-0}
          GALERA_UNDERSCALED_COUNT=$((GALERA_UNDERSCALED_COUNT + 1))
          underscaled_tolerance=${GALERA_UNDERSCALED_TOLERANCE:-2}

          if [[ $GALERA_UNDERSCALED_COUNT -ge $underscaled_tolerance ]]; then
            echo "$(date): [ACTION] Under-scaled for $GALERA_UNDERSCALED_COUNT consecutive checks — triggering auto-heal to restore $galera_sizing_target replicas"
            GALERA_UNDERSCALED_COUNT=0
            send_notification "GALERA_UNDERSCALED_HEAL" "Galera Under-Scaled Auto-Heal" \
              "StatefulSet has $galera_expected_size replicas but sizing target is $galera_sizing_target. Triggering auto-heal after $underscaled_tolerance consecutive detections." \
              "warning" "$DEPLOY_NAMESPACE"
            auto_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE"
            galera_status=$?
          else
            echo "$(date): [INFO] Under-scaled check $GALERA_UNDERSCALED_COUNT/$underscaled_tolerance — waiting before auto-heal"
            send_notification "GALERA_UNDERSCALED_MONITORING" "Galera Under-Scaled (Monitoring)" \
              "StatefulSet has $galera_expected_size/$galera_sizing_target replicas ($GALERA_UNDERSCALED_COUNT/$underscaled_tolerance checks before auto-heal)." \
              "info" "$DEPLOY_NAMESPACE"
            # Run health check normally for the current replica count
            check_and_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE" "$galera_expected_size" true
            galera_status=$?
          fi
        fi
      elif [[ "${MANUAL_MODE,,}" == "true" ]]; then
        # Reset under-scaled counter when at target
        GALERA_UNDERSCALED_COUNT=0
        echo "$(date): [MANUAL MODE] Skipping Galera auto-healing: manual intervention in progress"
        check_and_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE" "$galera_expected_size" false
        galera_status=$?
        if [[ "$galera_expected_size" == "0" ]]; then
          degraded_mode=1
          service_summary+=("  [NOTICE] mariadb-galera - intentionally parked (0 replicas, MANUAL MODE=true)")
          issue_details+=("  [INFO] Site is likely unavailable while database is intentionally parked")
          issue_details+=("  [INFO] To resume auto-healing: oc set env deployment/pod-health-monitor MANUAL_MODE=false -n $DEPLOY_NAMESPACE")
        elif [[ "$galera_expected_size" == "1" ]]; then
          degraded_mode=1
          service_summary+=("  [NOTICE] mariadb-galera - reduced availability mode (1 replica, MANUAL MODE=true)")
        fi
      else
        # At target or no sizing CSV — normal health check
        GALERA_UNDERSCALED_COUNT=0
        check_and_heal_galera_cluster "app.kubernetes.io/name=mariadb-galera" "$DEPLOY_NAMESPACE" "$galera_expected_size" true
        galera_status=$?
      fi
    else
      echo "$(date): No MariaDB Galera StatefulSet found - skipping Galera check"
      galera_status=0
    fi

    if [[ $galera_status -eq 2 ]]; then
      total_issues=$((total_issues + 5))  # Count as major issue
    elif [[ $galera_status -eq 1 ]]; then
      total_issues=$((total_issues + 1))
    fi

    last_galera_check=$current_time
  fi

  # -- Canary check: verify oc API connectivity is still alive --
  # If all selectors returned empty, it could mean the API is down, not that pods are gone.
  # A quick namespace query validates the connection is still working.
  if [[ $pods_checked -eq 0 && ${#service_summary[@]} -gt 0 ]]; then
    if ! oc get namespace "$DEPLOY_NAMESPACE" -o name &>/dev/null; then
      issue_details+=("  [ALERT] CANARY FAILED: oc API unreachable - all health checks may be stale")
      issue_details+=("     All services reported empty/failed - this is likely an API connectivity issue")
      total_issues=$((total_issues + 1))
    fi
  fi

  # Status report - detailed when issues found, periodic summary when healthy
  if [[ $total_issues -gt 0 || ${#issue_details[@]} -gt 0 ]]; then
    echo "============================================================"
    echo "$(date): Health check #$check_cycle - ${#issue_details[@]} finding(s), $total_issues action(s) taken ($pods_checked pods scanned)"
    for detail in "${service_summary[@]}"; do
      echo "$detail"
    done
    for detail in "${issue_details[@]}"; do
      echo "$detail"
    done
    echo "============================================================"
  elif [[ $((current_time - last_status_report)) -ge $STATUS_REPORT_INTERVAL ]]; then
    if [[ $degraded_mode -eq 1 ]]; then
      echo "$(date): Health check #$check_cycle - operational with degraded/parked database state ($pods_checked pods scanned, ${#error_counts[@]} tracked)"
    else
      echo "$(date): Health check #$check_cycle - all nominal ($pods_checked pods scanned, ${#error_counts[@]} tracked)"
    fi
    for detail in "${service_summary[@]}"; do
      echo "$detail"
    done
    last_status_report=$current_time
  fi

  # Wait for next check
  sleep $MONITORING_INTERVAL
done
