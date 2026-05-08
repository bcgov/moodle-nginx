# Pod-Health-Monitor Coordination Strategy

**Date:** 2026-04-15
**Status:** 🟡 DESIGN COMPLETE → READY FOR IMPLEMENTATION

---

## 🎯 Problem Statement

**Current Issue:** Race conditions between deployment automation and pod-health-monitor auto-heal can cause:
- Conflicting scaling operations (deploy scales up, auto-heal scales down simultaneously)
- Split-brain false positives (mid-deployment detection triggers unnecessary recovery)
- Resource thrashing (continuous restart loops during maintenance)
- Notification spam (alerts for expected maintenance windows)

**Root Cause:** No coordination layer between deployment scripts and monitoring

---

## ✅ Solution: Shared Coordination Layer

Transform pod-health-monitor from reactive healing service into **cluster health orchestrator with deployment coordination API**.

### **Core Components:**

1. **MANUAL_MODE Circuit Breaker** - Runtime toggle via ConfigMap
2. **Health Status API** - JSON snapshots + visual dashboard
3. **Namespace Safety Lock** - Prevent cross-environment impact
4. **Lighthouse Integration** - Auto-restore when site healthy
5. **State Persistence** - ConfigMaps (declarative, Kubernetes-native)

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    GITHUB ACTIONS DEPLOYMENT                     │
│                                                                  │
│  1. deploy-maintenance-message.sh                               │
│     ├─> Enable MANUAL_MODE (ConfigMap)                          │
│     ├─> Set deployment-state (maintenance=true)                 │
│     └─> Deploy maintenance page                                 │
│                                                                  │
│  2. deploy-mariadb-galera.sh                                    │
│     ├─> Validate namespace safety                               │
│     ├─> Query cluster health (JSON API)                         │
│     ├─> Run upgrade...                                          │
│     └─> Verify post-deployment health                           │
│                                                                  │
│  3. Lighthouse Monitor (PARALLEL)                               │
│     ├─> Audit site health                                       │
│     └─> lighthouse-completion-handler.sh                        │
│         ├─> If healthy: remove-maintenance-message.sh           │
│         └─> If unhealthy: alert + retain maintenance mode       │
└──────────────┬──────────────────────────────────────────────────┘
               │
               │ ConfigMap coordination
               ▼
┌─────────────────────────────────────────────────────────────────┐
│              POD-HEALTH-MONITOR (In-Cluster)                     │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ MANUAL_MODE Detection                                    │   │
│  │  ├─> Read ConfigMap (manual_mode)                        │   │
│  │  ├─> Check timeout (context-aware: 30m-4h)               │   │
│  │  ├─> Auto-detect deployment activity                     │   │
│  │  └─> Auto-enable/disable as needed                       │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Health Monitoring (Every 5 min)                          │   │
│  │  ├─> Generate health snapshot (JSON)                     │   │
│  │  ├─> Write to ConfigMap (cluster-health-state)           │   │
│  │  ├─> Print visual dashboard                              │   │
│  │  └─> If NOT in MANUAL_MODE:                              │   │
│  │      └─> Detect split-brain → auto_heal_galera_cluster() │   │
│  └─────────────────────────────────────────────────────────┘   │
│                                                                  │
│  ┌─────────────────────────────────────────────────────────┐   │
│  │ Emergency Maintenance (Split-Brain Detected)             │   │
│  │  ├─> Enable MANUAL_MODE                                  │   │
│  │  ├─> Run enable_emergency_maintenance()                  │   │
│  │  │   ├─> Moodle CLI maintenance mode                     │   │
│  │  │   └─> Route redirect to maintenance page              │   │
│  │  └─> Send critical notification                          │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

---

## 📋 Implementation Checklist

### **Phase 1: Foundation (Week 1)**

#### **1.1 Namespace Safety Lock** ✅ DESIGNED
**Files:**
- `openshift/scripts/utils/openshift.sh`
  - `get_current_namespace()`
  - `validate_namespace()`
  - `safe_namespace_operation()`

**Logic:**
```bash
# All scripts MUST validate before operating
CURRENT_NS=$(get_current_namespace) || exit 1
validate_namespace "$DEPLOY_NAMESPACE" || exit 1
```

**Protection:** Cannot accidentally operate on prod when logged into dev.

---

#### **1.2 MANUAL_MODE ConfigMap** ✅ DESIGNED
**Files:**
- `openshift/scripts/utils/openshift.sh`
  - `set_manual_mode()` - Enable/disable with timeout
  - `get_manual_mode()` - Read current state
  - `check_manual_mode_timeout()` - Safety timeout

**ConfigMap Schema:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pod-health-monitor-config
  labels:
    app: pod-health-monitor
data:
  manual_mode: "true"
  manual_mode_reason: "MariaDB Galera upgrade"
  manual_mode_timestamp: "2026-04-15T14:30:00Z"
  manual_mode_timeout: "2026-04-15T16:30:00Z"  # 2 hours from start
  manual_mode_timeout_minutes: "120"
```

**Timeouts (Context-Aware):**
- Right-sizing: 30 minutes
- Database upgrade: 2 hours (default)
- Major version upgrade: 4 hours
- Emergency maintenance: Until manual disable

---

#### **1.3 Deployment State Tracking** ✅ DESIGNED
**ConfigMap Schema:**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: deployment-state
  labels:
    app: pod-health-monitor
data:
  deployment_active: "true"              # "true", "false", "maintenance"
  deployment_name: "mariadb-galera-upgrade"
  deployment_type: "database"            # "database", "application", "maintenance"
  deployment_timestamp: "2026-04-15T14:30:00Z"
  maintenance_active: "true"             # Maintenance page deployed
  maintenance_reason: "Database upgrade"
  maintenance_site_accessible: "false"   # Site available to users
```

---

### **Phase 2: Health API (Week 2)**

#### **2.1 Health Snapshot Generation** ✅ DESIGNED
**Function:** `generate_cluster_health_snapshot()`

**JSON Schema:**
```json
{
  "timestamp": "2026-04-15T14:35:12Z",
  "namespace": "950003-prod",
  "mode": "false",
  "manual_mode_reason": "N/A",
  "deployment_detected": false,
  "maintenance_mode": {
    "route_disabled": false,
    "message_pod": "NotFound",
    "moodle_config": "disabled"
  },
  "cluster_health": {
    "mariadb-galera": {
      "status": "healthy",
      "replicas": "5/5",
      "synced": true,
      "split_brain": false
    },
    "php": {
      "status": "healthy",
      "replicas": "3/3"
    },
    "redis": {
      "status": "healthy"
    }
  },
  "warnings": [],
  "errors": []
}
```

**Storage:** Written to `/tmp/cluster-health.json` + optionally to ConfigMap `cluster-health-state`

---

#### **2.2 Visual Dashboard** ✅ DESIGNED
**Function:** `print_health_dashboard()`

**Output Example:**
```
╔════════════════════════════════════════════════════════════════════╗
║           CLUSTER HEALTH DASHBOARD (MONITORING POD)               ║
╠════════════════════════════════════════════════════════════════════╣
║ Timestamp: 2026-04-15T14:35:12Z
║ Mode: false (AUTO-HEAL ENABLED)
║ Deployment Active: false
╠════════════════════════════════════════════════════════════════════╣
║ COMPONENT STATUS
╠════════════════════════════════════════════════════════════════════╣
║ ✅ MariaDB Galera: healthy             Replicas: 5/5              ║
║ ✅ PHP:              healthy             Replicas: 3/3              ║
║ ✅ Redis:            healthy                                        ║
╠════════════════════════════════════════════════════════════════════╣
║ MAINTENANCE MODE
╠════════════════════════════════════════════════════════════════════╣
║ Route Disabled: false       Message Pod: NotFound                 ║
╚════════════════════════════════════════════════════════════════════╝
```

---

### **Phase 3: Deployment Integration (Week 3)**

#### **3.1 Enhanced deploy-maintenance-message.sh** ✅ IMPLEMENTED

**Changes:**
1. Namespace safety validation
2. Enable MANUAL_MODE before deployment
3. Set deployment-state ConfigMap
4. Wait for pod-health-monitor acknowledgment
5. Structured logging with step numbers
6. Final cluster state update

**Benefits:**
- Prevents auto-heal race conditions
- Coordinates with monitoring
- Safe cross-environment operation

---

#### **3.2 New: remove-maintenance-message.sh** ✅ IMPLEMENTED

**Flow:**
1. Validate namespace safety
2. Pre-flight health checks (unless --force)
3. Redirect routes to main application
4. Scale down + delete maintenance-message
5. Clear deployment-state ConfigMap
6. Query cluster health
7. Disable MANUAL_MODE (re-enable auto-heal)
8. Send success notification

**Safety:**
- Checks main app health before removal
- Validates database/PHP/Redis status
- --force flag bypasses checks (emergency use)

---

#### **3.3 Lighthouse Integration** ✅ DESIGNED

**New Script:** `lighthouse-completion-handler.sh`

**Integration Point:** `.github/workflows/lighthouse-monitor.yml`
```yaml
- name: Run Lighthouse Audit
  id: lighthouse
  run: bash ./config/lighthouse/run-lighthouse-audit.sh

- name: Lighthouse Completion Handler
  if: always()  # Run even if lighthouse failed
  run: bash ./openshift/scripts/lighthouse-completion-handler.sh
  env:
    LIGHTHOUSE_EXIT_CODE: ${{ steps.lighthouse.outcome }}
    LIGHTHOUSE_WARNINGS: ${{ steps.lighthouse.outputs.warnings }}
    DEPLOY_NAMESPACE: ${{ inputs.DEPLOY_NAMESPACE }}
    AUTO_DISABLE_MAINTENANCE: "YES"
```

**Logic:**
- Exit code 0 (all passed) → Auto-remove maintenance mode
- Exit code 1 (warnings) → Alert, leave maintenance mode
- Exit code 2+ (critical) → Alert, leave maintenance mode

**Benefits:**
- Site restoration confirmed by actual user testing (Lighthouse)
- Automatic recovery when safe
- Manual override available

---

### **Phase 4: Emergency Maintenance Integration (Week 4)**

#### **4.1 Integrate maintenance-mode.sh** 🔄 TO DO

**Current:** Standalone emergency maintenance script
**Goal:** Integrate with pod-health-monitor coordination

**Enhancement:**
```bash
# openshift/scripts/utils/openshift.sh

enable_emergency_maintenance() {
  local namespace="$1"
  local reason="$2"
  local moodle_maintenance="${3:-YES}"
  local openshift_maintenance="${4:-YES}"
  local timeout_minutes="${5:-240}"  # 4 hours default for emergencies

  # Namespace safety
  validate_namespace "$namespace" || return 1

  # Enable MANUAL_MODE first
  set_manual_mode "true" "$namespace" "Emergency: $reason" "$timeout_minutes"

  # Set deployment state
  oc create configmap deployment-state \
    --from-literal=deployment_active="emergency" \
    --from-literal=deployment_type="emergency_maintenance" \
    --from-literal=maintenance_reason="$reason" \
    --dry-run=client -o yaml | oc apply -f - -n "$namespace"

  # Moodle CLI maintenance mode
  if [[ "$moodle_maintenance" == "YES" ]]; then
    log_info "Enabling Moodle maintenance mode..."
    local cron_pod
    cron_pod=$(oc get pods -l app=moodle-cron \
      --field-selector=status.phase=Running \
      -n "$namespace" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [[ -n "$cron_pod" ]]; then
      oc exec -n "$namespace" "$cron_pod" -- \
        php /var/www/html/admin/cli/maintenance.php --enable
    fi
  fi

  # OpenShift route redirect
  if [[ "$openshift_maintenance" == "YES" ]]; then
    if oc get deployment maintenance-message -n "$namespace" &>/dev/null; then
      log_info "Scaling up maintenance-message..."
      oc scale deployment/maintenance-message -n "$namespace" --replicas=1

      # Redirect routes
      local routes route
      routes=$(oc get routes -n "$namespace" -o jsonpath='{.items[*].metadata.name}')
      for route in $routes; do
        oc patch route "$route" -n "$namespace" \
          -p '{"spec":{"to":{"name":"maintenance-message"}}}'
      done
    else
      log_warn "maintenance-message deployment not found - deploying..."
      bash "$(dirname "${BASH_SOURCE[0]}")/../deploy-maintenance-message.sh"
    fi
  fi

  send_notification "EMERGENCY_MAINTENANCE_ENABLED" \
    "🚨 Emergency Maintenance Mode" \
    "Emergency maintenance enabled. Reason: $reason. Site unavailable." \
    "error" "$namespace"
}
```

**Trigger:** Split-brain detection in pod-health-monitor

---

## 📊 State Persistence Strategy

### **ConfigMap vs PVC Decision**

| Aspect | ConfigMap | PVC |
|--------|-----------|-----|
| **Use Case** | Configuration, small state | Large data, mutable files |
| **Size Limit** | 1 MB | TB+ |
| **Mutability** | Replace-only | Read/write |
| **Declarative** | ✅ Yes | ❌ No |
| **Git Versioned** | ✅ Yes | ❌ No |
| **Rollback** | ✅ Automatic | ❌ Manual |
| **Cross-Pod Access** | ✅ Automatic | 🟡 Mount required |

**Decision:** Use ConfigMaps for coordination state

**Why:**
- State is small (<10 KB JSON)
- Declarative (Kubernetes-native)
- Auto-synced across pods
- Rollback via deployment history
- No additional PVC management

**When to Use PVC:**
- Application data (moodledata)
- Logs (too large for ConfigMap)
- User uploads
- Cache files

---

## 🔐 Safety Features

### **1. Namespace Isolation** ✅ CRITICAL
- Auto-detect current namespace via `oc project -q`
- Validate all operations against current context
- Block cross-namespace operations
- Require explicit `oc project` switch

### **2. Timeout Protection** ✅ CRITICAL
- Context-aware timeouts (30m - 4h)
- Automatic disable after timeout
- Extended timeout for emergencies
- Manual override available

### **3. Health Verification** ✅ RECOMMENDED
- Pre-flight checks before maintenance removal
- Lighthouse confirmation integration
- --force flag for emergency override
- Notifications for all state changes

### **4. State Recovery** ✅ AUTOMATIC
- ConfigMap survives pod restarts
- Auto-detection as fallback
- Timeout prevents infinite MANUAL_MODE
- Clear error messages with remediation steps

---

## 🧪 Testing Plan

### **Test 1: Normal Deployment**
```bash
# 1. Deploy maintenance page
./openshift/scripts/deploy-maintenance-message.sh

# 2. Verify MANUAL_MODE enabled
oc get configmap pod-health-monitor-config -o jsonpath='{.data.manual_mode}'
# Expected: "true"

# 3. Trigger split-brain (should NOT auto-heal)
# ... manually break Galera cluster ...
# pod-health-monitor should detect but NOT heal

# 4. Deploy main application
./openshift/scripts/deploy-mariadb-galera.sh

# 5. Run Lighthouse
# Should auto-trigger remove-maintenance-message.sh

# 6. Verify MANUAL_MODE disabled
oc get configmap pod-health-monitor-config -o jsonpath='{.data.manual_mode}'
# Expected: "false"
```

### **Test 2: Timeout Safety**
```bash
# 1. Enable MANUAL_MODE with 5-minute timeout
set_manual_mode "true" "$DEPLOY_NAMESPACE" "Test timeout" 5

# 2. Wait 6 minutes

# 3. Verify auto-disable
oc get configmap pod-health-monitor-config -o jsonpath='{.data.manual_mode}'
# Expected: "false"

# 4. Check logs for timeout notification
oc logs deployment/pod-health-monitor | grep "MANUAL_MODE_TIMEOUT"
```

### **Test 3: Namespace Safety**
```bash
# 1. Login to dev
oc project 950003-dev

# 2. Try to operate on prod
DEPLOY_NAMESPACE=950003-prod ./openshift/scripts/deploy-maintenance-message.sh
# Expected: ERROR - Namespace mismatch, operation blocked

# 3. Explicit switch
oc project 950003-prod
./openshift/scripts/deploy-maintenance-message.sh
# Expected: Success
```

---

## 🎯 Success Criteria

**Deployment Reliability:**
- ✅ Zero race conditions between deployment and auto-heal
- ✅ MANUAL_MODE timeout prevents infinite disable
- ✅ Namespace safety prevents cross-environment impact

**Operational Safety:**
- ✅ Emergency maintenance can be triggered automatically
- ✅ Site restoration confirmed by Lighthouse before traffic
- ✅ Clear state visibility (JSON API + dashboard)

**Monitoring Integration:**
- ✅ pod-health-monitor coordinates with deployments
- ✅ Split-brain detection works with MANUAL_MODE
- ✅ Health status queryable by deployment scripts

---

## 📖 Documentation Updates

1. ✅ This coordination strategy guide (complete)
2. 🔄 Update `docs/galera-deployment-best-practices.md` with coordination examples
3. 🔄 Update `README.md` with MANUAL_MODE explanation
4. 🔄 Create `docs/emergency-maintenance-procedures.md`
5. 🔄 Update `.github/workflows/deploy.yml` with lighthouse integration

---

**Last Updated:** 2026-04-15
**Next Review:** After Phase 1 implementation (estimated: 1 week)
