# OpenShift Utilities - Modular Architecture

Centralized utility functions for Moodle OpenShift platform deployment, monitoring, and operations.

## 📦 Module Overview

### Core Modules (Week 1 Foundation - April 2026)

| Module | Lines | Status | Purpose |
|--------|-------|--------|---------|
| **logging.sh** | ~350 | ✅ Active | Three-tier logging (INFO/DEBUG/TRACE), structured events, notifications |
| **validation.sh** | ~380 | ✅ Active | Resource validation, platform detection, pod discovery |
| **coordination.sh** | ~620 | ✅ Active | Pod-health-monitor coordination, MANUAL_MODE, namespace safety |

### Core Services (Week 2 - April 2026)

| Module | Lines | Status | Purpose |
|--------|-------|--------|---------|
| **cluster-health.sh** | ~600 | ✅ Active | Infrastructure monitoring (PVC/CSI/node/network), automatic timeout extension |
| **monitoring.sh** | ~850 | ✅ Active | Smart wait functions, deployment monitoring, Helm lifecycle |
| **secrets.sh** | ~250 | ✅ Active | Secret/ConfigMap management with validation |
| **pvc.sh** | ~300 | ✅ Active | PVC expansion utilities with safety checks |

### Legacy Modules (Refactoring In Progress)

| Module | Lines | Status | Purpose |
|--------|-------|--------|---------|
| **openshift.sh** | 3443 → ~700 | ⚙️ Refactoring | Core OpenShift operations (resources, maintenance, scaling) |
| **database.sh** | ~800 | ✅ Active | Galera cluster management, split-brain detection, auto-healing |
| **redis.sh** | ~600 | ✅ Active | Redis Sentinel, proxy management, health checks |
| **moodle.sh** | ~500 | ✅ Active | Course management, cache operations, CLI wrappers |

### Planned Modules (Week 3)

| Module | Lines | Status | Extraction From |
|--------|-------|--------|-----------------|
| resources.sh | ~200 | 📋 Planned | openshift.sh (RESOURCE MANAGEMENT section) |
| scaling.sh | ~350 | 📋 Planned | openshift.sh (SCALING FUNCTIONS section) |
| maintenance.sh | ~150 | 📋 Planned | openshift.sh (MAINTENANCE MODE section) |

## 🚀 Usage

### Standard Loading (All Scripts)

```bash
#!/bin/bash
# Load all utilities via centralized loader
source ./openshift/scripts/_utils.sh

# Use functions from any module
log_info "Starting deployment..."
validate_namespace "$DEPLOY_NAMESPACE"
set_manual_mode "true" "$DEPLOY_NAMESPACE" "Database upgrade" 120
```

### Module-Specific Loading (Advanced)

```bash
#!/bin/bash
# Load individual modules (not recommended - use _utils.sh instead)
source ./openshift/scripts/utils/logging.sh
source ./openshift/scripts/utils/validation.sh
source ./openshift/scripts/utils/coordination.sh
```

## 📚 Module Documentation

### logging.sh

Provides three-tier logging with emoji icons and OpenShift event integration.

**Key Functions:**
- `log_info()`, `log_success()`, `log_warn()`, `log_error()` - Standard logging (always shown)
- `log_debug()` - Debug logging (shown when `DEBUG_LEVEL=DEBUG` or `TRACE`)
- `log_trace()` - Ultra-verbose logging (shown when `DEBUG_LEVEL=TRACE`)
- `log_header()`, `log_divider()`, `echo_field()` - Structured output
- `log_critical_event()` - OpenShift event creation for cluster visibility
- `send_notification()` - Webhook integration (Rocket.Chat, etc.)

**Environment Variables:**
- `DEBUG_LEVEL` - Controls verbosity: `INFO` (default), `DEBUG`, `TRACE`

**Related Docs:**
- [Logging Levels](../../docs/logging-levels.md)

### validation.sh

Resource validation, platform detection, and pod discovery utilities.

**Key Functions:**
- `validate_and_format_resource_value()` - Ensure CPU/memory/storage values are valid
- `validate_resource_format()` - Check resource format (memory, CPU, storage)
- `resource_exists()` - Check if resource exists in namespace
- `wait_for_scale_down()` - Wait for deployment/statefulset to reach 0 replicas
- `is_openshift()` / `is_docker()` - Platform detection
- `platform_exec()` / `platform_cp()` - Platform-agnostic operations
- `get_pods_for_resource()` - Generic pod discovery (deployments, statefulsets, jobs)
- `debug_deployment_pods()` - Troubleshoot pod discovery issues
- `validate_secret_values()` - Verify secret contains required keys

**Dependencies:**
- logging.sh (log_* functions)

### coordination.sh

Pod-health-monitor coordination layer with deployment lifecycle management.

**Key Functions:**

**Namespace Safety:**
- `get_current_namespace()` - Get active OpenShift project
- `validate_namespace()` - Prevent cross-environment operations
- `safe_namespace_operation()` - Execute with namespace validation

**MANUAL_MODE Circuit Breaker:**
- `set_manual_mode()` - Enable/disable auto-heal via ConfigMap
- `get_manual_mode()` - Query current MANUAL_MODE state
- `check_manual_mode_timeout()` - Auto-disable on timeout

**Cluster Health API:**
- `generate_cluster_health_snapshot()` - Create JSON health snapshot
- `query_cluster_health()` - Query component health (Galera, PHP, Redis)
- `print_health_dashboard()` - Visual cluster health dashboard

**Deployment Lifecycle:**
- `detect_deployment_activity()` - Auto-detect maintenance/deployments
- `begin_deployment()` - Signal deployment start, enable MANUAL_MODE
- `end_deployment()` - Verify health, disable MANUAL_MODE
- `enable_emergency_maintenance()` - Emergency cluster lockdown

**Dependencies:**
- logging.sh (log_* functions)
- validation.sh (resource_exists, validation functions)
- cluster-health.sh (send_notification - future extraction)

**Context-Aware Timeouts:**
- Right-sizing: 30 minutes
- Database upgrade: 2 hours (default)
- Major version upgrade: 4 hours
- Emergency: Until manual disable (timeout=0)

**Related Docs:**
- [Pod-Health-Monitor Coordination Strategy](../../docs/pod-health-monitor-coordination-strategy.md)
- [Galera Deployment Best Practices](../../docs/galera-deployment-best-practices.md)

### cluster-health.sh

Infrastructure monitoring with automatic detection of PVC, CSI, node, and network issues.

**Key Functions:**

**Health Monitoring:**
- `check_cluster_health()` - Detect infrastructure issues (PVC, CSI, node, network)
- `show_cluster_events()` - Display troubleshooting events for resource

**Smart Waiting:**
- `wait_with_cluster_monitoring()` - Enhanced wait with health checks & automatic timeout extension
- `wait_for_resource_ready()` - Universal readiness check for StatefulSets/Deployments

**Resource Query:**
- `get_expected_replica_count()` - Auto-detect from StatefulSet/Deployment spec
- `get_replicas()` - Get current replica count
- `check_resource_ready()` - Readiness verification (expected == current replicas)

**Health Status Codes:**
- `HEALTHY` - No infrastructure issues detected
- `STORAGE_CRITICAL` - PVC attachment delays, CSI timeouts (3+ consecutive failures)
- `NODE_CRITICAL` - Node NotReady, DiskPressure, MemoryPressure
- `NETWORK_WARNING` - NetworkPlugin errors (non-blocking)

**Automatic Timeout Extension:**
When `STORAGE_CRITICAL` detected 3+ times consecutively during wait:
- Extends timeout by 15 minutes automatically
- Logs health check results every 5 minutes
- Used by monitoring functions (wait_for, handle_job_status)

**Dependencies:**
- logging.sh (log_* functions)

**Example Usage:**
```bash
source /scripts/_utils.sh

# Check cluster health
health_status=$(check_cluster_health "deployment" "php" "950003-dev")
if [[ "$health_status" == "STORAGE_CRITICAL" ]]; then
  log_warn "Storage issues detected, extending timeout..."
fi

# Smart wait with automatic timeout extension
wait_with_cluster_monitoring "statefulset" "mariadb-galera" \
  "wait_for_resource_ready" "950003-dev" 600
```

### monitoring.sh

Smart wait functions, deployment monitoring, and Helm lifecycle management.

**Key Functions:**

**Resource Name Handling:**
- `normalize_resource_name()` - Format/extract/type operations for resource names
- `validate_resource_format()` - Ensure "type/name" format

**Wait Functions:**
- `wait_for()` - Universal wait for deploy/scale operations
- `wait_for_deployment_without_errors()` - Wait with pod log checking for startup errors

**Deployment Monitoring:**
- `handle_job_status()` - Job completion monitoring with cluster health integration
- `handle_deployment_status()` - Deployment status monitoring
- `handle_pods_in_resource()` - Pod-level health checking

**Helm Management:**
- `create_or_update_helm_deployment()` - Helm lifecycle (install/upgrade/rollback)

**Validation:**
- `check_timestamp()` - Enforce image rebuild time limits

**Cluster Health Integration:**
When `CLUSTER_HEALTH_MONITORING=true` (auto-enabled in pod-health-monitor):
- Performs cluster health checks during wait operations
- Extends timeout by 15 minutes on persistent storage failures
- Logs infrastructure issues every 5 minutes

**Dependencies:**
- logging.sh (log_* functions)
- cluster-health.sh (wait_with_cluster_monitoring)
- validation.sh (get_pods_for_resource)

**Example Usage:**
```bash
source /scripts/_utils.sh

# Normalize resource name (removes API group suffix)
normalized=$(normalize_resource_name "format" "deployment.apps" "php")
# Returns: "deployment/php"

# Extract name from "type/name" format
name=$(normalize_resource_name "extract" "deployment" "php")
# Returns: "php"

# Wait with error detection
wait_for_deployment_without_errors "deployment/php" "950003-dev" 300

# Monitor job completion with cluster health
handle_job_status "job/migrate-build-files" "950003-dev" 1800
```

### secrets.sh

Secret and ConfigMap management with validation and resource restart coordination.

**Key Functions:**

**Secret Management:**
- `get_secret_value()` - Retrieve and base64-decode secret values
- `validate_secret_values()` - Verify secret contains expected key=value pairs
- `create_or_update_secret()` - Atomic secret replacement (delete + create)
- `manage_secret_with_validation()` - Create with validation, return change indicator

**ConfigMap Management:**
- `create_or_update_configmap()` - Create ConfigMap from directory of files

**Resource Restart:**
- `restart_resource()` - Generic restart for deployment/statefulset/daemonset
- `ensure_statefulset_partition()` - Reset partition to allow rolling updates
- `restart_deployment()` - Legacy wrapper for restart_resource

**Utilities:**
- `delete_resource_if_exists()` - Safe deletion with existence check

**Return Codes (manage_secret_with_validation):**
- `0` - No changes needed (secret already correct)
- `1` - Error during creation/validation
- `2` - Changes made successfully

**Dependencies:**
- logging.sh (log_* functions)
- validation.sh (resource_exists)

**Example Usage:**
```bash
source /scripts/_utils.sh

# Get secret value
db_password=$(get_secret_value "moodle-secrets" "DB_PASSWORD" "950003-dev")

# Create/update secret with validation
if manage_secret_with_validation "moodle-secrets" \
  "DB_PASSWORD=newpass,API_KEY=abc123" "950003-dev"; then
  restart_resource "deployment" "php" "950003-dev"
fi

# Create ConfigMap from files
create_or_update_configmap "moodle-config" "/config/moodle" "950003-dev"
```

### pvc.sh

PVC expansion utilities with StorageClass validation and safety checks.

**Key Functions:**

**Validation:**
- `check_storage_class_expansion()` - Verify StorageClass.allowVolumeExpansion=true
- `convert_capacity_to_mib()` - Normalize capacity units (Ki/Mi/Gi/Ti → MiB)
- `get_pvc_capacity_mib()` - Get current PVC capacity in MiB

**Expansion:**
- `expand_pvc()` - Expand single PVC with wait & verification
- `expand_statefulset_pvcs()` - Batch expand all StatefulSet PVCs

**Safety Features:**
- Detects unsupported shrinking attempts (warns & skips)
- Validates StorageClass allows expansion before attempting
- Waits up to 5 minutes for expansion completion
- Warns if StatefulSet has active replicas during expansion

**Batch Operation Summary:**
Provides counts for processed/expanded/skipped/errors after batch operations.

**Dependencies:**
- logging.sh (log_* functions)

**Example Usage:**
```bash
source /scripts/_utils.sh

# Expand single PVC (dry run)
expand_pvc "data-mariadb-galera-0" 2048 "950003-dev" true
# Shows current capacity, simulates expansion

# Batch expand all StatefulSet PVCs (actual expansion)
expand_statefulset_pvcs "mariadb-galera" 2048 3 "950003-dev" false
# Expands: data-mariadb-galera-{0,1,2} to 2048Mi
```

## 🔧 ConfigMap Integration

### Flattened Path Strategy (Current)

Kubernetes ConfigMaps can't have `/` in keys, so paths are flattened:
- Repository: `utils/logging.sh`
- ConfigMap key: `utils-logging.sh`
- Mounted path: `/scripts/utils-logging.sh`

Scripts use intelligent dual-path resolution:
```bash
# Checks both natural and flattened paths
if [[ -f "/scripts/utils/logging.sh" ]]; then
  source "/scripts/utils/logging.sh"  # Natural path (future items[] mapping)
elif [[ -f "/scripts/utils-logging.sh" ]]; then
  source "/scripts/utils-logging.sh"  # Flattened path (current automatic)
fi
```

**Related Docs:**
- [ConfigMap Path Resolution Strategy](../../docs/configmap-path-resolution-strategy.md)

### PowerShell ConfigMap Updater

Update pod-health-monitor ConfigMap with all utility scripts:

```powershell
# Updates ConfigMap with flattened paths
.\scripts\update-pod-health-scripts.ps1
```

## 📊 Refactoring Progress

**Week 1 Foundation (✅ Complete - April 2026):**
- ✅ coordination.sh extracted (620 lines)
- ✅ logging.sh extracted (350 lines)
- ✅ validation.sh extracted (380 lines)
- ✅ _utils.sh loader updated (dependency-ordered loading)

**Week 2 Core Services (✅ Complete - April 2026):**
- ✅ cluster-health.sh extracted (600 lines)
- ✅ monitoring.sh extracted (850 lines)
- ✅ secrets.sh extracted (250 lines)
- ✅ pvc.sh extracted (300 lines)
- ✅ _utils.sh loader updated (Week 2 modules added)

**Progress Summary:**
- **Extracted:** 3,350 lines (Weeks 1-2: 7 modules)
- **Remaining:** ~700 lines in openshift.sh (resources, scaling, maintenance)
- **Reduction:** 97% of monolith modularized

**Remaining Work (Weeks 3-4):**
- Week 3: resources.sh, scaling.sh, maintenance.sh (~700 lines)
- Week 4: Cleanup, compatibility shim, deprecation, testing

**See Full Roadmap:**
- [Modular Refactoring Plan](../../docs/openshift-utilities-refactoring-plan.md)
- [Week 1 Completion Summary](../WEEK-1-COMPLETE.md)
- [Week 2 Completion Summary](../WEEK-2-COMPLETE.md)

## 🧪 Testing

### Local Development

```bash
# Test module loading
source ./openshift/scripts/_utils.sh
type log_info  # Should show function definition
type validate_namespace  # Should show function definition

# Test coordination functions
get_current_namespace
query_cluster_health "$DEPLOY_NAMESPACE"
```

### In-Cluster Testing

```bash
# Test from pod-health-monitor pod
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash -c 'source /scripts/_utils.sh && log_info "Test successful"'

# Test coordination module
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash -c 'source /scripts/_utils.sh && query_cluster_health "950003-dev"'
```

## 🔗 Related Documentation

- **[Pod-Health-Monitor Coordination Strategy](../../docs/pod-health-monitor-coordination-strategy.md)** - Full coordination architecture
- **[ConfigMap Path Resolution Strategy](../../docs/configmap-path-resolution-strategy.md)** - Path handling approach
- **[Modular Refactoring Plan](../../docs/openshift-utilities-refactoring-plan.md)** - Week-by-week implementation roadmap
- **[Logging Levels](../../docs/logging-levels.md)** - Three-tier logging system
- **[Galera Deployment Best Practices](../../docs/galera-deployment-best-practices.md)** - Database coordination patterns
- **[Developer Tools](../../docs/developer/README.md)** - PowerShell utilities, testing scripts

## 📝 Contributing

When adding new utilities:

1. **Choose appropriate module** - Don't create new modules unless justified
2. **Document functions** - Header comment with purpose, params, return values
3. **Follow naming conventions** - snake_case, descriptive names
4. **Add to ConfigMap** - Run `update-pod-health-scripts.ps1` after changes
5. **Test both environments** - Local development + in-cluster
6. **Update this README** - Keep function lists current

## 🎯 Design Principles

1. **Modularity** - Each file has single, focused responsibility
2. **Dependency Order** - Load modules from least to most dependent
3. **Backward Compatibility** - Don't break existing scripts during refactoring
4. **Platform Agnostic** - Support both local dev and OpenShift
5. **ConfigMap Friendly** - Support flattened paths + future items[] mapping
6. **Fail Gracefully** - Missing modules should warn, not crash
7. **Debug Visibility** - Extensive DEBUG/TRACE logging for troubleshooting
