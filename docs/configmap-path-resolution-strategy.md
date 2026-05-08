# ConfigMap Path Resolution Strategy

**Date:** 2026-04-14
**Status:** ✅ IMPLEMENTED (Hybrid Approach)

---

## 🎯 Summary

**Problem:** Path mismatches between repo structure and in-cluster ConfigMap mounts.

**Solution:** Intelligent path resolution that supports BOTH current (automatic flattening) and future (natural subdirectories) approaches with **zero migration cost**.

---

## 📊 Quick Comparison

| Aspect | Current (Flattened) | Future (items[]) | Scripts Behavior |
|--------|---------------------|------------------|------------------|
| **ConfigMap Keys** | `utils-database.sh` | `utils-database.sh` | N/A |
| **Mount Strategy** | Direct mount (no items[]) | volumeMount.items[].path | Auto-detects |
| **In-Pod Path** | `/scripts/utils-database.sh` | `/scripts/utils/database.sh` | Checks both |
| **Repo Path** | `openshift/scripts/utils/database.sh` | Same | N/A |
| **Maintenance** | ✅ Automatic (discovery) | ❌ Manual (list items) | No changes needed |
| **Path Consistency** | ❌ Requires translation | ✅ Matches repo exactly | Transparent |
| **Local Dev** | ✅ Works (resolution) | ✅ Works (natural paths) | Same code |
| **GitHub Actions** | ✅ Works (resolution) | ✅ Works (natural paths) | Same code |

---

## 🔄 How It Works

### **1. Intelligent Path Detection in \_utils.sh**

```bash
# Detection order (best to fallback):
if [[ -d "$SCRIPT_DIR/utils" && -f "$SCRIPT_DIR/utils/openshift.sh" ]]; then
  # STRATEGY 1: Natural subdirectories (items[] or local dev)
  UTILS_DIR="$SCRIPT_DIR/utils"
  UTILS_PREFIX=""
elif [[ -f "$SCRIPT_DIR/utils-openshift.sh" ]]; then
  # STRATEGY 2: Flattened ConfigMap keys (current)
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX="utils-"
elif [[ -f "$SCRIPT_DIR/openshift.sh" ]]; then
  # STRATEGY 3: Flat mount (legacy)
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX=""
fi
```

**Result:** Scripts automatically load from correct location regardless of mount strategy.

---

### **2. Dual-Path Resolution in Specific Scripts**

Example from `database.sh` (galera_verify_cluster_address):

```bash
# Support both natural and flattened paths
local script_path=""
if [[ -f "/scripts/utils/galera-fix-cluster-address.sh" ]]; then
  script_path="/scripts/utils/galera-fix-cluster-address.sh"  # Preferred
elif [[ -f "/scripts/utils-galera-fix-cluster-address.sh" ]]; then
  script_path="/scripts/utils-galera-fix-cluster-address.sh"  # Fallback
fi
```

**Result:** Individual script references work in all environments.

---

## 🛠️ Current Implementation (Strategy 2)

**PowerShell:** `update-pod-health-scripts.ps1`
```powershell
# Flatten key names: utils/database.sh → utils-database.sh
$keyName = $relativePath.Replace('\', '-').Replace('/', '-')

# Create ConfigMap
oc create configmap openshift-scripts -n $Namespace --from-file=$keyName=$tempFile
```

**YAML:** `pod-health-monitor.yml`
```yaml
volumes:
  - name: openshift-scripts
    configMap:
      name: openshift-scripts
      defaultMode: 0755
      # NO items[] = all keys mounted at same level
```

**In-Pod Result:**
```
/scripts/
  ├── _utils.sh
  ├── monitor-pods.sh
  ├── utils-database.sh              # Flattened
  ├── utils-openshift.sh             # Flattened
  ├── utils-galera-fix-cluster-address.sh
  └── includes-colors.sh
```

**Benefits:**
- ✅ Automatic file discovery (no YAML updates when adding scripts)
- ✅ Works immediately
- ✅ Scripts compensate via intelligent loading

---

## 🚀 Future Implementation (Strategy 1) — OPTIONAL

**Why Consider?**
- Exact path parity with repo (easier mental model)
- No translation needed (documentation clarity)
- Matches industry best practices

**How to Migrate:**

### **Step 1: Generate items[] Mapping**

Uncomment section in `update-pod-health-scripts.ps1`:
```powershell
# Around line 270 - remove the <# ... #> block comment
Write-Host "      items:" -ForegroundColor Green
foreach ($script in $bashScripts) {
    $relativePath = $script.FullName.Substring($ScriptsPath.Length + 1)
    $keyName = $relativePath.Replace('\', '-').Replace('/', '-')
    $pathName = $relativePath.Replace('\', '/')

    Write-Host "      - key: $keyName" -ForegroundColor Green
    Write-Host "        path: $pathName" -ForegroundColor Green
}
```

Run script:
```powershell
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev
```

**Output:**
```yaml
      items:
      - key: _utils.sh
        path: _utils.sh
      - key: monitor-pods.sh
        path: monitor-pods.sh
      - key: utils-database.sh
        path: utils/database.sh
      - key: utils-openshift.sh
        path: utils/openshift.sh
      # ... (54 total)
```

---

### **Step 2: Update pod-health-monitor.yml**

```yaml
# openshift/pod-health-monitor.yml (line ~198)
volumes:
  - name: openshift-scripts
    configMap:
      name: openshift-scripts
      defaultMode: 0755
      items:
        # Copy generated items[] here
        - key: _utils.sh
          path: _utils.sh
        - key: utils-database.sh
          path: utils/database.sh
        # ... etc
```

---

### **Step 3: Apply & Verify**

```bash
# Apply updated YAML
oc apply -f openshift/pod-health-monitor.yml

# Restart deployment
oc rollout restart deployment/pod-health-monitor -n 950003-dev

# Verify natural paths
oc exec deployment/pod-health-monitor -n 950003-dev -- ls -la /scripts/utils/
# Should show:
#   database.sh
#   openshift.sh
#   galera-fix-cluster-address.sh
```

---

### **Step 4: No Script Changes Needed!**

Scripts automatically detect natural subdirectories and use them:

```bash
# _utils.sh detects this:
if [[ -d "$SCRIPT_DIR/utils" && -f "$SCRIPT_DIR/utils/openshift.sh" ]]; then
  # Uses natural paths automatically!
  UTILS_DIR="$SCRIPT_DIR/utils"
fi
```

---

## 📋 Decision Matrix

### **Keep Current Approach (Recommended) If:**
- ✅ Adding/removing scripts frequently (automatic discovery is valuable)
- ✅ Team prefers less YAML maintenance
- ✅ Path resolution working fine (no issues reported)
- ✅ Small script count (<100 files)

### **Migrate to items[] Mapping If:**
- ✅ Need exact path parity for compliance/auditing
- ✅ Troubleshooting path-related issues (already solved by resolution)
- ✅ Large script count (100+) where one-time mapping is worth consistency
- ✅ Team prefers explicit over automatic

**Current Recommendation:** **Keep flattened approach** since intelligent path resolution handles both transparently.

---

## 🧪 Testing

### **Verify Current Detection:**
```bash
oc exec deployment/pod-health-monitor -n 950003-dev -- bash -c '
  source /scripts/_utils.sh
  echo "UTILS_DIR: $UTILS_DIR"
  echo "UTILS_PREFIX: $UTILS_PREFIX"
  ls -la $UTILS_DIR
'
```

**Expected Output (Current):**
```
UTILS_DIR: /scripts
UTILS_PREFIX: utils-
/scripts/utils-database.sh
/scripts/utils-openshift.sh
```

**Expected Output (After items[] Migration):**
```
UTILS_DIR: /scripts/utils
UTILS_PREFIX:
/scripts/utils/database.sh
/scripts/utils/openshift.sh
```

---

### **Test Script Loading:**
```bash
oc exec deployment/pod-health-monitor -n 950003-dev -- bash -c '
  source /scripts/_utils.sh
  type check_galera_cluster_health
'
```

**Expected:** Function definition printed (proves utilities loaded correctly).

---

## 🔗 Related Documentation

- **Comprehensive Guide:** [docs/galera-deployment-best-practices.md](./galera-deployment-best-practices.md#configmap-path-strategy)
- **Script Implementation:** [openshift/scripts/\_utils.sh](../openshift/scripts/_utils.sh) (lines 64-110)
- **PowerShell Script:** [scripts/update-pod-health-scripts.ps1](../scripts/update-pod-health-scripts.ps1)
- **YAML Configuration:** [openshift/pod-health-monitor.yml](../openshift/pod-health-monitor.yml) (lines 197-207)

---

## ✅ Status

**Current State:** ✅ **PRODUCTION-READY**
- Scripts support both flattening strategies
- Auto-detection works in all environments
- Zero migration cost if we switch to items[]

**Future State:** 🔵 **OPTIONAL ENHANCEMENT**
- Can migrate to items[] anytime without code changes
- Use optional generator in PowerShell script
- Scripts automatically detect and use natural paths

---

**Last Updated:** 2026-04-14
**Review Date:** 2026-07-01 (or after significant repo structure changes)
