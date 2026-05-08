# OpenShift Utilities Refactoring Plan

**Current State:** openshift.sh = 3443 lines (monolithic)
**Target State:** 10+ focused modules (<500 lines each)

---

## 📊 Current Sections (Analysis)

From grep analysis, openshift.sh contains:

1. Cluster Health and Event Monitoring
2. Resource Management Functions
3. Galera-Aware Scaling
4. Validation Functions
5. Resource Utility Functions
6. Wait and Monitoring Functions
7. Logging and Error Handling
8. Maintenance Mode and Route Management
9. Secret Management
10. Monitoring and Status Functions
11. Image Pull Secrets Management
12. PVC Management and Expansion

---

## 🎯 Proposed Modular Structure

### **Core Modules (Refactor from openshift.sh)**

```
openshift/scripts/utils/
├── _utils.sh                    (Loader - existing)
├── database.sh                  (Galera/MariaDB - existing)
├── redis.sh                     (Redis operations - existing)
├── moodle.sh                    (Moodle operations - existing)
│
├── cluster-health.sh            (NEW - extracted)
│   ├── Health event monitoring
│   ├── log_critical_event()
│   ├── send_notification()
│   └── check_and_restart_pod()
│
├── resources.sh                 (NEW - extracted)
│   ├── create_or_update_configmap()
│   ├── delete_resource_if_exists()
│   ├── deploy_resource_from_template()
│   ├── update_image()
│   └── set_resources()
│
├── scaling.sh                   (NEW - extracted)
│   ├── scale_deployment()
│   ├── scale_resource()
│   ├── scale_galera_statefulset()
│   ├── ensure_statefulset_partition()
│   └── restart_statefulset()
│
├── validation.sh                (NEW - extracted)
│   ├── validate_and_format_resource_value()
│   ├── resource_exists()
│   └── wait_for_scale_down()
│
├── monitoring.sh                (NEW - extracted)
│   ├── wait_for()
│   ├── wait_for_resource_ready()
│   ├── get_expected_replica_count()
│   ├── check_pod_logs()
│   └── check_pod_errors()
│
├── logging.sh                   (NEW - extracted)
│   ├── log_*() functions
│   ├── echo_field()
│   └── log_divider()
│
├── maintenance.sh               (NEW - extracted)
│   ├── manage_maintenance_mode()
│   ├── patch_all_routes()
│   └── create_hpa()
│
├── secrets.sh                   (NEW - extracted)
│   ├── create_secret_if_not_exists()
│   └── create_or_update_image_pull_secret()
│
├── pvc.sh                       (NEW - extracted)
│   ├── expand_pvc_if_needed()
│   └── wait_for_pvc_expansion()
│
└── coordination.sh              (NEW - for pod-health-monitor)
    ├── get_current_namespace()
    ├── validate_namespace()
    ├── safe_namespace_operation()
    ├── set_manual_mode()
    ├── get_manual_mode()
    ├── check_manual_mode_timeout()
    ├── generate_cluster_health_snapshot()
    ├── query_cluster_health()
    ├── print_health_dashboard()
    ├── detect_deployment_activity()
    ├── begin_deployment()
    ├── end_deployment()
    └── enable_emergency_maintenance()
```

---

## 📋 Refactoring Strategy

### **Phase 1: Create New Modules (Extract from openshift.sh)**

**Extraction Order (Low Risk → High Risk):**

1. **logging.sh** (Low risk - pure utility functions)
   - Lines: ~200-300
   - Dependencies: None
   - Used by: Everyone

2. **validation.sh** (Low risk - pure validation)
   - Lines: ~150-200
   - Dependencies: logging.sh
   - Used by: resources.sh, scaling.sh

3. **secrets.sh** (Low risk - isolated functionality)
   - Lines: ~100-150
   - Dependencies: logging.sh
   - Used by: Deployment scripts

4. **pvc.sh** (Low risk - isolated functionality)
   - Lines: ~200-300
   - Dependencies: logging.sh, validation.sh
   - Used by: Database deployment

5. **cluster-health.sh** (Medium risk - notifications)
   - Lines: ~400-500
   - Dependencies: logging.sh
   - Used by: monitoring.sh, database.sh

6. **monitoring.sh** (Medium risk - wait functions)
   - Lines: ~500-600
   - Dependencies: logging.sh, validation.sh
   - Used by: Deployment scripts, scaling.sh

7. **resources.sh** (Medium risk - core functions)
   - Lines: ~400-500
   - Dependencies: logging.sh, validation.sh, monitoring.sh
   - Used by: All deployment scripts

8. **maintenance.sh** (Medium risk - route management)
   - Lines: ~300-400
   - Dependencies: logging.sh, resources.sh
   - Used by: Deployment scripts, maintenance scripts

9. **scaling.sh** (HIGH risk - critical operations)
   - Lines: ~400-500
   - Dependencies: logging.sh, validation.sh, monitoring.sh, database.sh
   - Used by: All deployment scripts, right-sizing

10. **coordination.sh** (NEW - no extraction risk)
    - Lines: ~400-500
    - Dependencies: logging.sh, validation.sh, cluster-health.sh
    - Used by: deploy-maintenance-message.sh, pod-health-monitor

---

### **Phase 2: Update _utils.sh Loader**

**Current loader logic:**
```bash
# Detect structure (flattened vs natural)
if [[ -f "$SCRIPT_DIR/utils-openshift.sh" ]]; then
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX="utils-"
elif [[ -f "$SCRIPT_DIR/openshift.sh" ]]; then
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX=""
else
  UTILS_DIR="$SCRIPT_DIR/utils"
  UTILS_PREFIX=""
fi

# Load modules
source "${UTILS_DIR}/${UTILS_PREFIX}openshift.sh"
source "${UTILS_DIR}/${UTILS_PREFIX}redis.sh"
source "${UTILS_DIR}/${UTILS_PREFIX}database.sh"
source "${UTILS_DIR}/${UTILS_PREFIX}moodle.sh"
```

**New loader logic (after refactoring):**
```bash
# Core order: logging first (everyone depends on it)
CORE_MODULES=(
  "logging"       # Must be first (provides log_* functions)
  "validation"    # Must be early (provides validation functions)
  "cluster-health"
  "monitoring"
  "secrets"
  "pvc"
  "resources"
  "maintenance"
  "scaling"
  "coordination"  # NEW
)

# Load core modules
for module in "${CORE_MODULES[@]}"; do
  module_path="${UTILS_DIR}/${UTILS_PREFIX}${module}.sh"
  if [[ -f "$module_path" ]]; then
    source "$module_path" || {
      echo "ERROR: Failed to load $module_path" >&2
      return 1
    }
  else
    echo "WARNING: Module not found: $module_path" >&2
  fi
done

# Load domain-specific modules (order doesn't matter after core)
DOMAIN_MODULES=(
  "redis"
  "database"
  "moodle"
)

for module in "${DOMAIN_MODULES[@]}"; do
  module_path="${UTILS_DIR}/${UTILS_PREFIX}${module}.sh"
  if [[ -f "$module_path" ]]; then
    source "$module_path"
  fi
done
```

---

### **Phase 3: Deprecation Strategy**

**Keep openshift.sh temporarily as compatibility shim:**

```bash
#!/bin/bash
# =============================================================================
# openshift.sh - DEPRECATED COMPATIBILITY SHIM
# =============================================================================
# This file is deprecated in favor of modular utilities.
# It remains for backward compatibility during migration.
#
# NEW CODE: Source _utils.sh which loads all modules automatically
# OLD CODE: Can still source openshift.sh directly (loads all modules)
#
# Removal Date: After all scripts migrated to _utils.sh
# =============================================================================

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load modular utilities via _utils.sh
if [[ -f "$SCRIPT_DIR/../_utils.sh" ]]; then
  source "$SCRIPT_DIR/../_utils.sh"
else
  echo "ERROR: Cannot find _utils.sh" >&2
  exit 1
fi

# Backward compatibility: ensure all legacy functions still work
# (They're now loaded from individual modules via _utils.sh)
```

**Migration timeline:**
- Week 1-2: Create new modules, test in dev
- Week 3-4: Update deployment scripts to use _utils.sh
- Week 5: Deprecation notice in openshift.sh
- Week 6+: Remove openshift.sh after verification

---

## 🧪 Testing Strategy

### **Test 1: Module Loading**
```bash
# Test individual module
source ./openshift/scripts/utils/logging.sh
type log_info  # Should output function definition

# Test via _utils.sh
source ./openshift/scripts/_utils.sh
type scale_galera_statefulset  # Should work (from scaling.sh)
type validate_namespace  # Should work (from coordination.sh)
```

### **Test 2: Deployment Scripts**
```bash
# Test each deployment script still works
./openshift/scripts/deploy-mariadb-galera.sh
./openshift/scripts/deploy-redis-sentinel.sh
./openshift/scripts/right-sizing.sh
```

### **Test 3: Backward Compatibility**
```bash
# Old scripts that source openshift.sh directly should still work
source ./openshift/scripts/utils/openshift.sh
type create_or_update_configmap  # Should work
```

---

## 📊 Size Estimates (After Split)

| Module | Lines | Complexity |
|--------|-------|------------|
| logging.sh | ~250 | Low |
| validation.sh | ~180 | Low |
| secrets.sh | ~120 | Low |
| pvc.sh | ~280 | Medium |
| cluster-health.sh | ~450 | Medium |
| monitoring.sh | ~550 | Medium |
| resources.sh | ~480 | Medium |
| maintenance.sh | ~350 | Medium |
| scaling.sh | ~480 | High |
| coordination.sh | ~420 | Medium |
| **Total Core** | **~3,560** | |
| database.sh (existing) | ~1,200 | High |
| redis.sh (existing) | ~400 | Medium |
| moodle.sh (existing) | ~600 | Medium |
| **GRAND TOTAL** | **~5,760** | |

**Note:** Total is higher than current 3443 because:
- Better documentation (function headers)
- Clearer separation (less code reuse)
- New coordination.sh module (~420 lines)

---

## ✅ Benefits of Modular Approach

**Maintainability:**
- ✅ Each file <600 lines (easier to navigate)
- ✅ Clear ownership (scaling.sh owns all scaling logic)
- ✅ Faster to find functions (by category)

**Testing:**
- ✅ Test modules independently
- ✅ Mock dependencies easily
- ✅ Isolated failures don't break everything

**Collaboration:**
- ✅ Multiple devs can work on different modules
- ✅ Clearer git history (by module)
- ✅ Less merge conflicts

**Deployment:**
- ✅ Selective loading (skip modules not needed)
- ✅ Lazy loading possible (load on demand)
- ✅ ConfigMap size management (split if needed)

---

## 🚀 Implementation Order (Recommended)

### **Week 1: Foundation**
1. Create coordination.sh (NEW - no risk)
2. Extract logging.sh (low risk, high value)
3. Extract validation.sh (low risk, needed by coordination.sh)
4. Update _utils.sh loader to support modules
5. Test in dev environment

### **Week 2: Medium Risk Modules**
6. Extract cluster-health.sh
7. Extract monitoring.sh
8. Extract secrets.sh
9. Extract pvc.sh
10. Test all deployment scripts

### **Week 3: High Risk Modules**
11. Extract resources.sh (many dependencies)
12. Extract maintenance.sh
13. Extract scaling.sh (most critical - test extensively)
14. Update all deployment scripts
15. Full integration testing

### **Week 4: Cleanup**
16. Create openshift.sh compatibility shim
17. Update documentation
18. Announce deprecation
19. Monitor production deployments
20. Remove openshift.sh after verification period

---

## 📖 Documentation Updates

1. Create `openshift/scripts/utils/README.md` - Module index
2. Update each module with comprehensive header
3. Update `docs/galera-deployment-best-practices.md` with imports
4. Create migration guide for custom scripts
5. Update CONTRIBUTING.md with module guidelines

---

**Decision Required:** Proceed with modular refactoring?

**Recommendation:** YES - Start with Week 1 (coordination.sh + logging.sh)
- Low risk (new + simple extraction)
- Immediate value (pod-health-monitor coordination)
- Foundation for future modules
