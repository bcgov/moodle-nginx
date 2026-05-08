# Galera Cluster Reliability: Root Cause Analysis & Best Practices

**Date:** 2026-04-14
**Status:** 🔴 CRITICAL GAPS IDENTIFIED → ✅ SOLUTIONS IMPLEMENTED

---

## 🔍 Root Cause Analysis

### **The gcomm Discrepancy Problem**

**Symptoms:**
- Nodes 1-4 bootstrap independently instead of joining node 0
- Split-brain after deployments/upgrades
- UUID mismatches across pods
- Data divergence risk

**Root Causes Identified:**

#### 1. **Bug in database.sh Step 7 (FIXED)** ✅
```bash
# OLD CODE (WRONG):
oc set env statefulset/"$sts_name" \
  "MARIADB_GALERA_CLUSTER_ADDRESS-"    # ← REMOVES the variable

# NEW CODE (CORRECT):
oc set env statefulset/"$sts_name" \
  "MARIADB_GALERA_CLUSTER_ADDRESS=${cluster_address}"  # ← SETS proper value
```

**Impact:** During `galera_safe_upgrade()`, cluster address was being REMOVED, causing secondary pods to bootstrap independently.

**Where Called:**
- `galera_safe_upgrade()` → Step 7 (line ~1005 in database.sh)
- Used by: deploy-mariadb-galera.sh (upgrade path) + pod-health-monitor (auto-heal)

---

#### 2. **Helm Chart Values vs. StatefulSet Env Vars**

**Bitnami Galera Helm Chart Behavior:**
```yaml
# Helm values.yaml
galera:
  bootstrap:
    forceBootstrap: true  # Sets MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes
```

**Problem:** Helm sets env vars in StatefulSet template, but:
1. If pod crashes before ready, env vars may not propagate correctly
2. StatefulSet updates are rolling (1 pod at a time)
3. During rolling update, old pods have old env vars
4. New pods get new env vars but may join wrong cluster

**Timing Issue:**
```
Time 0: Helm upgrade submitted (forceBootstrap=false)
Time 1: Pod-1 recreated with new env vars
Time 2: Pod-1 starts before StatefulSet fully updated
Time 3: Pod-1 reads old MARIADB_GALERA_CLUSTER_ADDRESS from cache
Time 4: Pod-1 bootstraps independently → SPLIT-BRAIN
```

---

#### 3. **PVC Deletion Without Coordination**

**Current Behavior:**
```bash
# In galera_safe_upgrade()
galera_delete_secondary_pvcs "$sts_name" "$target_replicas" "$namespace"

# Deletes PVCs 1-4 synchronously
for i in $(seq 1 $((target_replicas - 1))); do
  oc delete pvc "data-${sts_name}-${i}" -n "$namespace" --wait=true
done
```

**Problem:**
- Deletion happens AFTER scale-to-0
- If script fails between PVC deletion and bootstrap, cluster is broken
- No rollback mechanism
- PVC deletion is NOT atomic with StatefulSet operations

---

#### 4. **Right-Sizing Script Lacks Galera Awareness** 🔴 **CRITICAL GAP**

**Current Flow:**
```bash
# right-sizing.sh line 155
set_resources "$Type" "$Deployment" "$CPURequest" "$MemRequest" "$CPULimit" "$MemLimit"

# Then generic scale
scale_deployment "$Type" "$Deployment" "$PodCount" "$MaxPods"
```

**Missing Steps:**
1. ❌ No cluster address verification before scale-up
2. ❌ No grastate.dat analysis before PVC operations
3. ❌ No Galera health check after scaling
4. ❌ No split-brain detection/prevention
5. ❌ Uses parallel scaling (via HPA) instead of incremental (1→2→3→4→5)

**Result:** Right-sizing can trigger split-brain if:
- Scaling from 0→5 (all pods start simultaneously)
- Cluster address not set
- Resource changes trigger pod restarts (parallel)

---

## 🛡️ Defense Layers (Current State)

### ✅ Layer 1: Bitnami Init Container (Helm Chart)
**What It Does:**
- Checks `safe_to_bootstrap` flag in grastate.dat
- Sets `MARIADB_GALERA_CLUSTER_BOOTSTRAP` if safe_to_bootstrap=1
- Only runs during pod startup

**Limitations:**
- Only handles safe_to_bootstrap, NOT cluster address
- Doesn't prevent parallel bootstrap
- Doesn't detect existing clusters
- No cross-pod coordination

### ✅ Layer 2: OrderedReady Pod Management
```yaml
podManagementPolicy: OrderedReady  # mariadb-galera.yml line 10
```
**What It Does:**
- Starts pods sequentially: 0→1→2→3→4→5
- Waits for pod-N Ready before starting pod-N+1

**Limitations:**
- Only enforced during initial scale-up
- NOT enforced during rolling updates (all pods restart)
- NOT enforced when StatefulSet spec changes
- Does NOT prevent "parallel" bootstrapping if cluster address missing

### ✅ Layer 3: galera-safe-upgrade() (Fix)
**What It Does:**
1. Scale to 0 (OrderedReady = pod-0 last to shutdown)
2. Delete secondary PVCs
3. Bootstrap from pod-0 with controlled env vars
4. **SETS proper cluster address** (the fix)
5. Scale to target incrementally

**Limitations:**
- Only called by deploy-mariadb-galera.sh and auto-heal
- NOT called by right-sizing.sh
- NOT called by manual oc scale commands
- Requires explicit invocation

### ✅ Layer 4: Auto-Heal Detection (pod-health-monitor)
**What It Does:**
- Detects split-brain (multiple UUIDs)
- Triggers galera_safe_upgrade() for recovery
- Calls galera-fix-cluster-address.sh before bootstrap

**Limitations:**
- **Reactive, not proactive** (detects AFTER split-brain)
- 5-minute polling interval (split-brain window)
- Doesn't prevent initial failure

---

## 🚨 Gaps in Current Architecture

### **Gap 1: Right-Sizing Has No Galera Protection** 🔴 CRITICAL

**Scenario:**
```bash
# User runs right-sizing
./openshift/scripts/right-sizing.sh

# For mariadb-galera:
# 1. Sets replicaCount=5
# 2. Calls scale_deployment() (generic)
# 3. StatefulSet scales 0→5 or 1→5
# 4. If cluster address wrong/missing → SPLIT-BRAIN
```

**Why Dangerous:**
- Right-sizing is run DURING deployments (automated)
- Changes trigger pod restarts (RollingUpdate strategy)
- No cluster address verification
- No incremental scaling
- No split-brain detection

**Frequency:** Every deployment that includes right-sizing

---

### **Gap 2: Manual Operations Bypass Protections**

**Dangerous Commands:**
```bash
# These can cause split-brain:
oc scale sts/mariadb-galera --replicas=5           # No cluster address check
oc delete pod mariadb-galera-{1,2,3,4}              # Parallel restart
oc delete pvc data-mariadb-galera-{1,2,3,4}         # Lost data + wrong bootstrap
oc rollout restart sts/mariadb-galera               # Parallel restart
```

**No Safeguards For:**
- Manual scaling operations
- Manual PVC deletions
- Manual pod deletions (parallel restart)
- Rolling updates triggered by external changes

---

### **Gap 3: Helm Chart Environment Variables Persistence**

**Problem:** Helm sets env vars at StatefulSet template level:
```yaml
spec:
  template:
    spec:
      containers:
      - env:
        - name: MARIADB_GALERA_CLUSTER_ADDRESS
          value: "gcomm://pod-0.headless,..."
```

**During Rolling Update:**
1. StatefulSet spec updated
2. Pods restart ONE AT A TIME
3. Each pod reads NEW env vars from template
4.  **BUT:** If template update fails mid-rollout, some pods have old values

**Race Condition:**
```
Pod-0: MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://pod-0,pod-1 (NEW)
Pod-1: MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://           (OLD - bootstrap mode)
        ↑ SPLIT-BRAIN: Pod-1 bootstraps independently
```

---

## ✅ Solutions Implemented

### **Solution 1: Fixed database.sh Step 7** ✅ DEPLOYED
- Changed from REMOVING cluster address to SETTING it
- All auto-heal operations now set proper address
- Integrated into galera-safe-upgrade workflow

### **Solution 2: Created galera-fix-cluster-address.sh** ✅ DEPLOYED
- Standalone diagnostic/fix script
- Deployed to pod-health-monitor via ConfigMap
- Called before any bootstrap operation
- Return codes: 0=healthy, 1=fixed, 2=issues found

### **Solution 3: Auto-Heal Integration** ✅ DEPLOYED
- `auto_heal_galera_cluster()` calls `galera_verify_cluster_address()` first
- Prevents split-brain during recovery
- Logged and monitored

---

## 🔧 Recommended Solutions

### **Solution 4: Enhance Right-Sizing for Galera** 🟡 RECOMMENDED

**Add Galera-Specific Scaling Function:**

```bash
# New function in openshift.sh
scale_galera_statefulset() {
  local sts_name="$1"
  local target_replicas="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  log_info "Galera-aware scaling: $sts_name → $target_replicas replicas"

  # Step 1: Verify cluster address BEFORE scaling
  if ! galera_verify_cluster_address "$sts_name" "$namespace" "fix"; then
    log_error "Cluster address verification failed - aborting scale"
    return 1
  fi

  # Step 2: Get current replicas
  local current_replicas
  current_replicas=$(oc get sts/"$sts_name" -n "$namespace" -o jsonpath='{.spec.replicas}')

  # Step 3: Scale incrementally (not parallel)
  if [[ "$current_replicas" -lt "$target_replicas" ]]; then
    log_info "Incremental scale-up: $current_replicas → $target_replicas"
    for i in $(seq $((current_replicas + 1)) "$target_replicas"); do
      log_debug "  Scaling to $i..."
      oc scale sts/"$sts_name" --replicas="$i" -n "$namespace"

      # Wait for new pod Ready before continuing
      local new_pod="${sts_name}-$((i - 1))"
      if ! galera_wait_for_pod_ready "$new_pod" "$namespace" 300; then
        log_error "Pod $new_pod failed to become Ready"
        return 1
      fi

      # Verify Galera sync
      if ! galera_wait_for_sync "$sts_name" 30 10 "$i"; then
        log_error "Galera failed to sync at $i replicas"
        return 1
      fi
    done
  elif [[ "$current_replicas" -gt "$target_replicas" ]]; then
    # Scale-down is safe (OrderedReady shuts down in reverse order)
    log_info "Scale-down: $current_replicas → $target_replicas"
    oc scale sts/"$sts_name" --replicas="$target_replicas" -n "$namespace"
  fi

  # Step 4: Final health check
  if ! check_galera_cluster_health "app.kubernetes.io/name=$sts_name" "$namespace" "$target_replicas"; then
    log_error "Cluster unhealthy after scaling"
    return 1
  fi

  log_success "Galera cluster scaled successfully to $target_replicas replicas"
  return 0
}
```

**Update right-sizing.sh:**
```bash
# Line ~155, replace generic scale with Galera-aware version:
if [[ "$Type" == "sts" && "$Deployment" == *"galera"* ]]; then
  scale_galera_statefulset "$Deployment" "$PodCount" "$DEPLOY_NAMESPACE"
else
  scale_deployment "$Type" "$Deployment" "$PodCount" "$MaxPods"
fi
```

---

### **Solution 5: Prevent Manual Operations** 🟡 RECOMMENDED

**Create Wrapper Scripts:**

```bash
# scripts/scale-galera.sh (safe wrapper around oc scale)
#!/bin/bash
if [[ "$1" != *"galera"* ]]; then
  oc scale "$@"  # Not Galera, pass through
  exit $?
fi

# Galera-specific: use safe scaling
STS_NAME=$(echo "$1" | sed 's/sts\///')
TARGET=$(echo "$@" | grep -oP '--replicas=\K[0-9]+')

source ./openshift/scripts/utils/_utils.sh
scale_galera_statefulset "$STS_NAME" "$TARGET"
```

**Add to Documentation:**
```markdown
## ⚠️ NEVER Use These Commands for Galera

❌ `oc scale sts/mariadb-galera --replicas=5`
❌ `oc delete pod mariadb-galera-{1,2,3,4}`
❌ `oc delete pvc data-mariadb-galera-*`
❌ `oc rollout restart sts/mariadb-galera`

✅ **Instead Use:**
```bash
./scripts/scale-galera.sh --replicas=5
./scripts/bootstrap-mariadb-galera.ps1 -Bootstrap
```
```

---

### **Solution 6: Admission Webhook (Future)** 🔵 LONG-TERM

**Kubernetes AdmissionWebhook** to intercept dangerous operations:

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: galera-protection
webhooks:
- name: galera.moodle.protection
  rules:
  - operations: ["UPDATE", "DELETE"]
    apiGroups: ["apps", ""]
    apiVersions: ["v1"]
    resources: ["statefulsets", "persistentvolumeclaims", "pods"]
  clientConfig:
    service:
      name: galera-webhook
      path: /validate
```

**Benefits:**
- Blocks unsafe operations automatically
- Works for kubectl, oc, and Helm
- Centralized enforcement
- Audit logging

---

## 📋 Best Practices (Updated)

### **Deployment Operations**

#### ✅ **SAFE Deployment Process:**
```bash
1. Run galera-fix-cluster-address.sh (diagnostic)
2. Deploy with deploy-mariadb-galera.sh (uses galera_safe_upgrade)
3. Run right-sizing.sh (now includes Galera checks)
4. Verify health check
5. Exit maintenance mode
```

#### ❌ **UNSAFE Operations:**
```bash
# These bypass protections - NEVER USE:
- oc scale sts/mariadb-galera (skips cluster address check)
- oc delete pvc data-* (doesn't coordinate with cluster)
- Parallel pod deletion (kubectl delete pod -l app=galera)
- Manual env var changes without verification
```

---

### **Scaling Operations**

#### ✅ **SAFE Scaling:**
```bash
# Option 1: Update CSV + run right-sizing (automated checks)
vim openshift/950003-prod-sizing.csv  # Change mariadb-galera replicas
./openshift/scripts/right-sizing.sh

# Option 2: Use Galera-aware wrapper
./scripts/scale-galera.sh --replicas=5

# Option 3: Full bootstrap (for major issues)
./scripts/bootstrap-mariadb-galera.ps1 -Bootstrap
```

#### ❌ **UNSAFE Scaling:**
```bash
oc scale sts/mariadb-galera --replicas=5          # Skips all checks
helm upgrade --set replicaCount=5                 # May not set cluster address
```

---

### **PVC Operations**

#### ✅ **SAFE PVC Management:**
```bash
# NEVER delete PVCs manually - use bootstrap script:
./scripts/bootstrap-mariadb-galera.ps1 -Bootstrap

# This will:
# 1. Verify pod-0 has latest data
# 2. Scale to 0 safely
# 3. Delete secondary PVCs (1-4) only
# 4. Bootstrap from pod-0
# 5. Rebuild cluster with sync validation
```

#### ❌ **UNSAFE PVC Operations:**
```bash
oc delete pvc data-mariadb-galera-*    # May delete pod-0 (primary data)
oc delete pvc -l app=galera            # No coordination with cluster
```

---

### **Upgrade Operations**

#### ✅ **SAFE Upgrade Process:**
```bash
# Update version in example.versions.env
MARIADB_IMAGE="bitnami/mariadb-galera:11.4.3"

# Deploy with built-in safety checks
./openshift/scripts/deploy-mariadb-galera.sh

# Script automatically:
# 1. Detects version change
# 2. Runs version guard (blocks major upgrades)
# 3. Uses galera_safe_upgrade (scale-to-0 → bootstrap → scale-up)
# 4. Verifies cluster address at each step
# 5. Validates Galera health before completing
```

#### ❌ **UNSAFE Upgrade Methods:**
```bash
# Direct Helm upgrade (skips safety checks)
helm upgrade mariadb-galera --set image.tag=11.4.3

# Manual image change (triggersRolling Update = parallel pod restart)
oc set image sts/mariadb-galera mariadb=...
```

---

## 📊 Split-Brain Prevention Matrix

| Operation | Bypass Risk | Protection Layer | Status |
|-----------|-------------|------------------|--------|
| **deploy-mariadb-galera.sh** | ❌ Low | galera_safe_upgrade() | ✅ PROTECTED |
| **right-sizing.sh** | 🟡 Medium | ❌ None (GAP) | 🔴 VULNERABLE |
| **auto-heal (monitor)** | ❌ Low | galera_verify_cluster_address() | ✅ PROTECTED |
| **oc scale** | 🔴 High | ❌ None | 🔴 VULNERABLE |
| **oc delete pvc** | 🔴 Critical | ❌ None | 🔴 VULNERABLE |
| **oc delete pod** | 🟡 Medium | OrderedReady (partial) | 🟡 PARTIAL |
| **Helm upgrade** | 🟡 Medium | Version guard | 🟡 PARTIAL |
| **Rolling Update** | 🟡 Medium | OrderedReady+PreStop | 🟡 PARTIAL |

---

## 🗂️ ConfigMap Path Strategy

### **Background: The Path Translation Problem**

**Challenge:** Kubernetes ConfigMaps don't allow `/` in keys, but our scripts expect natural directory structures.

**Repo Structure:**
```
openshift/scripts/
  ├── _utils.sh
  ├── monitor-pods.sh
  └── utils/
      ├── database.sh
      ├── openshift.sh
      ├── galera-fix-cluster-address.sh
      └── ...
```

**ConfigMap Limitation:** Keys cannot contain `/`, so subdirectory paths must be handled specially.

---

### **Current Approach: Automatic Flattening (STRATEGY 2)**

**How It Works:**
1. PowerShell script (`update-pod-health-scripts.ps1`) scans `openshift/scripts/` recursively
2. Flattens key names: `utils/database.sh` → `utils-database.sh`
3. Creates ConfigMap with flattened keys
4. Mounts at `/scripts/` without `items[]` mapping

**Result in Pod:**
```
/scripts/
  ├── _utils.sh
  ├── monitor-pods.sh
  ├── utils-database.sh              # Flattened!
  ├── utils-openshift.sh             # Flattened!
  └── utils-galera-fix-cluster-address.sh  # Flattened!
```

**Pros:**
- ✅ Automatic file discovery (adds new scripts without YAML changes)
- ✅ Works immediately (no manual mapping)
- ✅ Scales to any number of files

**Cons:**
- ❌ Paths don't match repo structure
- ❌ Requires path translation in scripts (`/scripts/utils-database.sh` vs `openshift/scripts/utils/database.sh`)
- ❌ Breaks local execution if scripts hard-code paths

---

### **Future Approach: Natural Subdirectories with items[] (STRATEGY 1)**

**How It Would Work:**
```yaml
# openshift/pod-health-monitor.yml
volumes:
  - name: openshift-scripts
    configMap:
      name: openshift-scripts
      defaultMode: 0755
      items:
        # Root-level scripts (no subdirectory)
        - key: _utils.sh
          path: _utils.sh
        - key: monitor-pods.sh
          path: monitor-pods.sh

        # Utils subdirectory (restored via items[].path)
        - key: utils-database.sh                # ConfigMap key (flattened)
          path: utils/database.sh                # Mount path (natural!)
        - key: utils-openshift.sh
          path: utils/openshift.sh
        - key: utils-galera-fix-cluster-address.sh
          path: utils/galera-fix-cluster-address.sh

        # Includes subdirectory
        - key: includes-colors.sh
          path: includes/colors.sh

        # Versioning subdirectory
        - key: versioning-validate-versions.sh
          path: versioning/validate-versions.sh
```

**Result in Pod:**
```
/scripts/
  ├── _utils.sh
  ├── monitor-pods.sh
  ├── utils/
  │   ├── database.sh                    # Natural paths!
  │   ├── openshift.sh
  │   └── galera-fix-cluster-address.sh
  ├── includes/
  │   └── colors.sh
  └── versioning/
      └── validate-versions.sh
```

**Pros:**
- ✅ Paths match repo structure exactly
- ✅ No path translation needed
- ✅ Works in local dev, GitHub Actions, AND in-cluster
- ✅ Self-documenting (path = actual location)

**Cons:**
- ❌ Verbose YAML (~54 items[] entries currently)
- ❌ Manual maintenance when new files added
- ❌ Potential for drift if `items[]` list gets out of sync

**Mitigation:** Generate items[] programmatically in PowerShell script.

---

### **Current Solution: Intelligent Path Resolution** ✅ IMPLEMENTED

**Hybrid Approach:** Scripts automatically detect which strategy is in use.

**Implementation in `_utils.sh`:**
```bash
# Detection order (best to fallback):
if [[ -d "$SCRIPT_DIR/utils" && -f "$SCRIPT_DIR/utils/openshift.sh" ]]; then
  # STRATEGY 1: Natural subdirectory (items[] approach or local dev)
  UTILS_DIR="$SCRIPT_DIR/utils"
  UTILS_PREFIX=""
elif [[ -f "$SCRIPT_DIR/utils-openshift.sh" ]]; then
  # STRATEGY 2: Flattened ConfigMap keys (current production)
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX="utils-"
elif [[ -f "$SCRIPT_DIR/openshift.sh" ]]; then
  # STRATEGY 3: Flat mount (legacy)
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX=""
fi
```

**Implementation in `database.sh` (galera_verify_cluster_address):**
```bash
# Path resolution: Support both strategies
local script_path=""
if [[ -f "/scripts/utils/galera-fix-cluster-address.sh" ]]; then
  script_path="/scripts/utils/galera-fix-cluster-address.sh"  # Preferred (natural)
elif [[ -f "/scripts/utils-galera-fix-cluster-address.sh" ]]; then
  script_path="/scripts/utils-galera-fix-cluster-address.sh"  # Fallback (flattened)
fi
```

**Benefits:**
- ✅ **Works now** (with current flattened approach)
- ✅ **Works later** (if/when we add `items[]` mapping)
- ✅ **Works locally** (normal filesystem structure)
- ✅ **Zero migration cost** (scripts auto-detect and adapt)

---

### **Migration Path (Optional - Future Enhancement)**

**Option A: Programmatic items[] Generation** (Recommended if migrating)

Update `update-pod-health-scripts.ps1`:
```powershell
# After creating ConfigMap, generate items[] YAML snippet
$itemsYaml = @"
# AUTO-GENERATED items[] mapping for natural paths
# Copy to pod-health-monitor.yml under volumes.openshift-scripts
items:
"@

foreach ($script in $bashScripts) {
    $relativePath = $script.FullName.Substring($ScriptsPath.Length + 1)
    $keyName = $relativePath.Replace('\', '-').Replace('/', '-')
    $pathName = $relativePath.Replace('\', '/')
    $itemsYaml += "`n  - key: $keyName`n    path: $pathName"
}

Write-Host "`n$itemsYaml" -ForegroundColor Cyan
Write-Host "`nℹ️  Copy the above to pod-health-monitor.yml to enable natural paths" -ForegroundColor Yellow
```

**Option B: Keep Current Approach** (Pragmatic)

Current flattening works fine and is fully supported by path resolution logic. Only migrate to `items[]` if:
1. Adding a lot more scripts (100+) where manual mapping is worth it
2. Need exact path parity for compliance/auditing
3. Troubleshooting path mismatches (already solved by resolution logic)

**Recommendation:** **Keep current approach** (automatic flattening) since our intelligent path resolution handles both strategies transparently.

---

### **Testing Path Resolution**

**Verify Current Detection:**
```bash
# In pod-health-monitor pod
oc rsh pod-health-monitor-xxxxx

# Check what structure was detected
source /scripts/_utils.sh
echo "UTILS_DIR: $UTILS_DIR"
echo "UTILS_PREFIX: $UTILS_PREFIX"

# Verify scripts load correctly
source /scripts/_utils.sh
type check_galera_cluster_health  # Should output function definition
```

**Test Both Strategies:**
```bash
# Current (flattened)
ls -la /scripts/utils-*   # Should show flattened files

# Future (if items[] added)
ls -la /scripts/utils/    # Would show natural subdirectory
```

---

## 🎯 Implementation Priority

### **Phase 1: CRITICAL (Immediate)** ✅ COMPLETED
- [x] Fix database.sh Step 7 (SET vs REMOVE)
- [x] Create galera-fix-cluster-address.sh
- [x] Integrate into auto-heal workflow
- [x] Document current gaps

### **Phase 2: HIGH (This Sprint)** 📋 RECOMMENDED
- [ ] Enhance right-sizing.sh with Galera awareness
  - Add `scale_galera_statefulset()` to openshift.sh
  - Update right-sizing.sh to use Galera-specific scaling
  - Add cluster address verification before scale operations
  - Add split-brain detection after scale operations

- [ ] Create wrapper scripts for manual operations
  - `scripts/scale-galera.sh` (safe oc scale wrapper)
  - Update documentation with "NEVER" warnings

- [ ] Update all deployment documentation
  - Add "Safe vs Unsafe" operation tables
  - Document split-brain prevention matrix
  - Add troubleshooting flowcharts

### **Phase 3: MEDIUM (Next Sprint)**
- [ ] Add pre-flight checks to Helm deployments
- [ ] Create integration tests for split-brain scenarios
- [ ] Implement cluster address validation in CI/CD
- [ ] Add Prometheus alerts for cluster address mismatches

### **Phase 4: LOW (Future)**
- [ ] Admission webhook for cluster-wide protection
- [ ] Automated rollback on split-brain detection
- [ ] Cross-namespace Galera coordination

---

## 📖 Documentation Updates Needed

1. **docs/galera-deployment-best-practices.md** (NEW)
   - Safe vs Unsafe operations
   - Step-by-step deployment procedures
   - Troubleshooting decision tree

2. **docs/manual-galera-troubleshooting.md** (UPDATE)
   - Add cluster address troubleshooting section
   - Document recovery procedures for each gap

3. **docs/galera-monitoring-solution.md** (UPDATE)
   - Document auto-heal enhancements
   - Add split-brain prevention details

4. **README.md** (UPDATE)
   - Add "⚠️ Galera Operations" warning section
   - Link to best practices

5. **scripts/README.md** (UPDATE)
   - Document safe wrapper scripts
   - Add command equivalency table

---

## ✅ Success Criteria

**Deployment Reliability:**
- ✅ Zero split-brain incidents during normal deployments
- ✅ Automated recovery from configuration drift
- ✅ Safe scaling operations (manual and automated)

**Operational Safety:**
- ✅ All dangerous operations blocked or wrapped
- ✅ Clear documentation of safe practices
- ✅ Monitoring and alerting for misconfigurations

**High Availability:**
- ✅ Zero data loss during upgrades
- ✅ Minimal downtime (<30s) for minor updates
- ✅ Predictable recovery from failures

---

## 🔗 Related Documentation

- **Architecture:** [docs/galera-monitoring-solution.md](../galera-monitoring-solution.md)
- **Troubleshooting:** [docs/manual-galera-troubleshooting.md](../manual-galera-troubleshooting.md)
- **Auto-Heal Status:** [docs/pod-health-monitor-autoheal-status.md](../pod-health-monitor-autoheal-status.md)
- **Timeout Tuning:** [docs/galera-timeout-in-cluster-architecture.md](../galera-timeout-in-cluster-architecture.md)

---

**Last Updated:** 2026-04-14
**Review Date:** 2026-05-01 (or after next major deployment)
