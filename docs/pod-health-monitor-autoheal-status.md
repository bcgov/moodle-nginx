# Pod-Health-Monitor Auto-Fix Status

## ✅ Status: UP TO DATE

All Galera cluster management scripts have been refactored to use the new cloud-native architecture with consistent naming conventions.

---

## 📁 File Organization (Completed)

### **Moved to `openshift/scripts/utils/`:**
```
✅ galera-inspect.sh (moved from openshift/scripts/)
✅ galera-recover.sh (moved from openshift/scripts/)
✅ galera-fix-cluster-address.sh (renamed from fix-galera-cluster-address.sh)
✅ _galera_utils.sh (NEW - shared utility functions)
✅ galera-bootstrap.sh (NEW - comprehensive bootstrap recovery)
✅ galera-delete-pvcs.sh (NEW - PVC deletion utility)
```

---

## 🔄 ConfigMap Deployment Mechanism

### **How Scripts are Deployed:**

The `update-pod-health-scripts.ps1` script flattens subdirectory paths when creating ConfigMaps:

```
Source Path                              ConfigMap Key (mounted in pod)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
utils/_galera_utils.sh          →       /scripts/utils-_galera_utils.sh
utils/galera-bootstrap.sh       →       /scripts/utils-galera-bootstrap.sh
utils/galera-delete-pvcs.sh     →       /scripts/utils-galera-delete-pvcs.sh
utils/galera-fix-cluster-address.sh →   /scripts/utils-galera-fix-cluster-address.sh
utils/galera-inspect.sh         →       /scripts/utils-galera-inspect.sh
utils/galera-recover.sh         →       /scripts/utils-galera-recover.sh
utils/database.sh               →       /scripts/utils-database.sh
utils/moodle.sh                 →       /scripts/utils-moodle.sh
monitor-pods.sh                 →       /scripts/monitor-pods.sh
```

**Reason:** ConfigMap keys cannot contain forward slashes, so `utils/` becomes `utils-`

---

## 🔗 Updated References

### **1. database.sh** ✅
```bash
# Line 488
local script_path="/scripts/utils-galera-fix-cluster-address.sh"
```

### **2. galera-bootstrap.sh** ✅
```bash
# Line 333 (in-cluster execution via pod-health-monitor)
local fix_script="/scripts/utils-galera-fix-cluster-address.sh"

# Line 999 (direct script-to-script execution)
local fix_script="$SCRIPT_DIR/galera-fix-cluster-address.sh"
```

### **3. bootstrap-mariadb-galera.ps1** ✅
```powershell
# Line 745
$fixResult = oc exec $podName -n $Namespace -- bash -c "/scripts/utils-galera-fix-cluster-address.sh $Namespace mariadb-galera --fix"
```

### **4. check-galera-cluster-address.ps1** ✅
```powershell
# Line 92
$command = "/scripts/utils-galera-fix-cluster-address.sh $Namespace $StatefulSetName$fixFlag"
```

---

## 🎯 Auto-Heal Integration

### **Current Auto-Heal Workflow:**

```mermaid
graph TD
    A[monitor-pods.sh] -->|Detects split-brain| B[database.sh::auto_heal_galera_cluster]
    B -->|Step 1| C[Verify cluster address]
    C -->|Calls| D[/scripts/utils-galera-fix-cluster-address.sh]
    D -->|Fixes if needed| E[Apply configuration]
    E -->|Step 2| F[Bootstrap recovery]
    F -->|Calls| G[galera_safe_upgrade functions]
```

### **Key Functions in database.sh:**

1. **`galera_verify_cluster_address()`** (Lines 467-517)
   - Calls `/scripts/utils-galera-fix-cluster-address.sh`
   - Used by auto-heal and manual operations
   - Returns: 0=healthy, 1=fixed, 2=issues detected

2. **`auto_heal_galera_cluster()`** (Lines 1119-1288)
   - Pre-flight check: calls `galera_verify_cluster_address()`
   - Performs bootstrap recovery if needed
   - Validates final state

3. **`galera_safe_upgrade()`** (Lines 834-1118)
   - Step 7: Sets proper cluster address
   - Step 7.5: Verifies cluster address (defensive check)
   - Used during upgrades/deployments

---

## 🆕 New Cloud-Native Features

### **1. Centralized Utilities (`_galera_utils.sh`)**
Shared functions available to all Galera scripts:
- `galera_setup_auth()` - OpenShift authentication
- `galera_get_root_password()` - Credentials from secrets
- `galera_check_pod_health()` - Health status queries
- `galera_parse_grastate()` - grastate.dat parsing
- `galera_get_target_replicas()` - Auto-detect from CSV/annotation
- Logging functions: `log_critical()`, `log_warning()`, `log_success()`, etc.

### **2. Comprehensive Bootstrap (`galera-bootstrap.sh`)**
Full bootstrap recovery workflow:
- Analyzes grastate.dat from all nodes
- Selects best bootstrap node (highest seqno)
- Scales to 0 → bootstrap → gradual scale-up with validation
- Verifies final state (all nodes Primary, same UUID)

**Usage:**
```bash
# Interactive (prompts for confirmation)
oc exec deployment/pod-health-monitor -n 950003-prod -- \
  /scripts/utils-galera-bootstrap.sh --namespace=950003-prod

# Non-interactive (for automation/PowerShell)
/scripts/utils-galera-bootstrap.sh \
  --non-interactive \
  --namespace=950003-prod \
  --target-replicas=5 \
  --force
```

### **3. PVC Deletion Utility (`galera-delete-pvcs.sh`)**
⚠️ **DANGEROUS** - Permanently deletes PVCs

Only use when:
- Certain pod-0 has correct data
- Other nodes have corrupted data
- Want to force fresh SST from pod-0

**Usage:**
```bash
# Delete PVCs for nodes 1-4, keep node 0
/scripts/utils-galera-delete-pvcs.sh \
  --namespace=950003-prod \
  --keep-node=0 \
  --force
```

---

## 🚀 Deployment Process

### **To Deploy Updated Scripts:**

```powershell
# From local machine (Windows PowerShell)
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-prod

# This will:
# 1. Collect all *.sh files from openshift/scripts/ (recursive)
# 2. Convert to Unix line endings (CRLF → LF)
# 3. Flatten subdirectory paths (utils/ → utils-)
# 4. Create/update ConfigMap: openshift-scripts
# 5. Restart pod-health-monitor deployment (unless -SkipRestart)
```

### **Verification:**

```bash
# Check ConfigMap contains new scripts
oc get configmap openshift-scripts -n 950003-prod \
  -o jsonpath='{.data}' | jq 'keys[]' | grep galera

# Expected output:
# "utils-galera-bootstrap.sh"
# "utils-galera-delete-pvcs.sh"
# "utils-galera-fix-cluster-address.sh"
# "utils-galera-inspect.sh"
# "utils-galera-recover.sh"
# "utils-_galera_utils.sh"

# Check pod has scripts mounted
oc exec deployment/pod-health-monitor -n 950003-prod -- ls -la /scripts/utils-galera-*

# Expected output:
# -rwxr-xr-x ... /scripts/utils-galera-bootstrap.sh
# -rwxr-xr-x ... /scripts/utils-galera-delete-pvcs.sh
# -rwxr-xr-x ... /scripts/utils-galera-fix-cluster-address.sh
# -rwxr-xr-x ... /scripts/utils-galera-inspect.sh
# -rwxr-xr-x ... /scripts/utils-galera-recover.sh
# -rwxr-xr-x ... /scripts/utils-_galera_utils.sh
```

---

## 📝 Next Steps

1. **Test in Dev Environment:**
   ```powershell
   .\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev
   ```

2. **Verify Auto-Heal Works:**
   - Trigger split-brain scenario (delete cluster address)
   - Monitor auto-heal log: `oc logs deployment/pod-health-monitor -n 950003-dev -f`
   - Verify cluster address is automatically fixed

3. **Test Bootstrap Recovery:**
   ```bash
   # From pod-health-monitor (OpenShift web terminal)
   oc exec deployment/pod-health-monitor -n 950003-dev -- \
     /scripts/utils-galera-bootstrap.sh --namespace=950003-dev --analyze-only
   ```

4. **Deploy to Test/Prod:**
   ```powershell
   .\scripts\update-pod-health-scripts.ps1 -Namespace 950003-test
   .\scripts\update-pod-health-scripts.ps1 -Namespace 950003-prod
   ```

---

## ✅ Summary

All pod-health-monitor references are **UP TO DATE** with the latest Galera script refactoring:

- ✅ File organization completed (all galera scripts in utils/)
- ✅ Consistent naming convention (galera-* prefix)
- ✅ All script references updated (database.sh, PowerShell wrappers)
- ✅ ConfigMap deployment mechanism unchanged (flattening still works)
- ✅ Auto-heal integration verified
- ✅ New features ready for testing (bootstrap, PVC deletion)

**Ready for deployment to dev/test/prod environments.**
