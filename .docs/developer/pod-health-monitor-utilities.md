# Pod-Health-Monitor Utility Integration

## Overview

Leverage existing utilities and functions from `_utils.sh` by mounting them into the pod-health-monitor pod.

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

# Now you have access to ALL utility functions:
check_galera_cluster_health 'app.kubernetes.io/name=mariadb-galera' '950003-prod'
scale_deployment "deployment" "$PHP_DEPLOYMENT_NAME" "1" "1"
patch_route "moodle-web" "maintenance-message"
clear_moodle_cache_deployment "$PHP_DEPLOYMENT_NAME" "$NAMESPACE"
```

## Benefits

✅ **No Code Duplication** - Reuse existing tested utilities instead of rewriting in PowerShell
✅ **Full Bash Ecosystem** - Access to all functions in `_utils.sh` and modules
✅ **Quick Updates** - PowerShell scripts only update ConfigMaps, ~1 minute vs 45-minute deployment
✅ **Consistent Behavior** - Same code runs in pods and bash deployment scripts
✅ **Easy Debugging** - Can shell into pod and run functions interactively

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

## Files Updated

1. [openshift/scripts/deploy-template.sh](../../openshift/scripts/deploy-template.sh) - Adds galera-recovery-scripts ConfigMap
2. [openshift/pod-health-monitor.yml](../../openshift/pod-health-monitor.yml) - Mounts galera-scripts volume
3. [openshift/scripts/galera-inspect.sh](../../openshift/scripts/galera-inspect.sh) - Sources _utils.sh, uses utility functions
4. [scripts/update-pod-health-scripts.ps1](./update-pod-health-scripts.ps1) - Universal updater for all ConfigMaps

## Migration from Old Approach

**Old (Deprecated)**:
- `update-galera-recovery-scripts.ps1` - Just updated galera scripts
- `update-monitor-pods-script.ps1` - Just updated monitor script
- Standalone bash scripts without utilities

**New (Current)**:
- `update-pod-health-scripts.ps1` - Updates ALL ConfigMaps with `-ScriptType` parameter
- All bash scripts source `/scripts/utils/_utils.sh` and use existing functions
- Single source of truth for all utilities

## Next Steps

1. **Test in Dev**:
   ```powershell
   .\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev
   ```

2. **Verify Scripts Available**:
   ```bash
   oc exec -it deployment/pod-health-monitor -n 950003-dev -- ls -la /scripts/utils/
   ```

3. **Test Galera Inspection**:
   ```bash
   oc exec -it deployment/pod-health-monitor -n 950003-dev -- bash /scripts/utils/galera-inspect.sh
   ```

4. **Deploy to Production** when tested and validated
