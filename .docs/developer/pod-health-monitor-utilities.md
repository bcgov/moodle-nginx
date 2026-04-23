# Pod-Health-Monitor Utility Integration

## Overview

Leverage existing utilities and functions from `_utils.sh` by mounting them into the pod-health-monitor pod.

## Monitoring Behavior

### Per-Service Restart Thresholds

| Service | Selector | Threshold | Age Gate | Cooldown | Rationale |
|---------|----------|-----------|----------|----------|----------|
| redis-proxy | `app=redis-proxy` | 1 | **bypassed** | **bypassed** | Stateless proxy, cannot self-heal, immediate restart required |
| redis-node | `app.kubernetes.io/name=redis` | 1 | 120s | 300s | CRITICAL/lost errors mean stale connections, needs restart |
| PHP | `deployment=php` | 3 (default) | 120s | 300s | Most resilient, self-heals most transient errors |
| cron | `app=cron` | — | — | — | Observe-only (transient DB/Redis errors, auto-recovers) |
| web | `deployment=web` | — | — | — | Observe-only (nginx auto-recovers, restart won't help) |

### Restart Loop Protection

During cluster maintenance (node drains, rolling restarts), pods restart with transient startup errors that resolve once the cluster settles. Two safeguards prevent the monitor from making things worse:

1. **Pod Age Gate** (`POD_MIN_AGE_SECONDS=120`) — Skip pods younger than 2 minutes. Startup errors (connection refused to Redis/DB) resolve on their own.
2. **Per-Service Cooldown** (`RESTART_COOLDOWN_SECONDS=300`) — After restarting a service, suppress further restarts for 5 minutes. Prevents: restart → new pod → startup error → restart loop.

redis-proxy bypasses both safeguards because it cannot recover from errors without a restart.

Both values are configurable via environment variables on the pod-health-monitor deployment:

```bash
oc set env deployment/pod-health-monitor \
  POD_MIN_AGE_SECONDS=180 \
  RESTART_COOLDOWN_SECONDS=600 \
  -n 950003-dev
```

## Architecture

### ConfigMaps Mounted in pod-health-monitor:

1. **check-pod-logs-script** → `/scripts/utils/`
   - `_utils.sh` - Main utility loader
   - `openshift.sh` - Core OpenShift operations
   - `redis.sh` - Redis-specific operations
   - `database.sh` - Galera/MariaDB operations (including `check_galera_cluster_health`)
   - `moodle.sh` - Moodle-specific operations
   - `galera-inspect.sh` - Cluster diagnostics (sources `_utils.sh`)
   - `galera-recover.sh` - Split-brain recovery (sources `_utils.sh`)

2. **pod-health-monitor-script** → `/opt/monitor/`
   - `monitor-pods.sh` - Continuous monitoring loop

3. **migrate-courses** → `/var/www/html/migrate-courses/`
   - Course migration tools

## Usage

### Quick Updates from Windows

```powershell
# Update all ConfigMaps
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev

# Update only monitoring script
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev -ScriptType Monitor

# Update utilities (includes galera diagnostic scripts)
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev -ScriptType Utils
```

### Execute from Pod with Full Utilities

```bash
# Galera cluster inspection (uses database.sh utilities)
oc exec -it deployment/pod-health-monitor -n 950003-prod -- \
  bash /scripts/utils/galera-inspect.sh

# Split-brain recovery (uses database.sh utilities)
oc exec -it deployment/pod-health-monitor -n 950003-prod -- \
  bash /scripts/utils/galera-recover.sh

# Interactive shell with utilities
oc exec -it deployment/pod-health-monitor -n 950003-prod -- bash

# Inside the pod:
source /scripts/utils/_utils.sh

# Access ALL utility functions:
check_galera_cluster_health 'app.kubernetes.io/name=mariadb-galera' '950003-prod'
scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "1" "1"
patch_route "moodle-web" "maintenance-message"
clear_moodle_cache_deployment "$PHP_DEPLOYMENT_NAME" "$NAMESPACE"
```

## Available Utility Functions in Pod

Once you source `/scripts/utils/_utils.sh`, you have access to:

### Galera/MariaDB Operations (database.sh):
- `check_galera_cluster_health()` - Comprehensive cluster health check with split-brain detection
- `check_mariadb_replication_status()` - Replication status verification
- `auto_heal_galera_node()` - Automatic node recovery

### OpenShift Operations (openshift.sh):
- `scale_deployment()` - Scale deployments
- `patch_route()` - Update route targets
- `create_or_update_configmap()` - ConfigMap management
- `wait_for()` - Wait for resource readiness
- `delete_resource_if_exists()` - Safe resource deletion

### Redis Operations (redis.sh):
- `update_redis_proxy_after_scaling()` - Reconfigure proxy
- `check_redis_health()` - Health validation

### Moodle Operations (moodle.sh):
- `clear_moodle_cache_deployment()` - Cache clearing across pods
- `run_moodle_cli()` - Execute Moodle CLI commands
