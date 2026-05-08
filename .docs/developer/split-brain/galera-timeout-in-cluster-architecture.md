# Galera Timeout Management - In-Cluster Architecture

## Philosophy: Cloud-Native Configuration Management

**Principle:** Heavy lifting happens IN the cluster, PowerShell scripts are for diagnostics and setup only.

```
┌─────────────────────────────────────────────┐
│  Developer Workstation (PowerShell)          │
│                                              │
│  ✓ Upload utilities to cluster              │
│  ✓ Run diagnostics                          │
│  ✓ View logs and configuration              │
│  ✓ Trigger in-cluster operations            │
│                                              │
│  ✗ Direct ConfigMap edits                   │
│  ✗ Pod restarts                             │
│  ✗ Heavy orchestration logic                │
└──────────────────┬───────────────────────────┘
                   │
                   │ Upload utilities
                   │ Trigger operations
                   │
                   v
┌─────────────────────────────────────────────┐
│  OpenShift Cluster (pod-health-monitor)      │
│                                              │
│  ✓ Apply timeout configuration              │
│  ✓ Update ConfigMaps                        │
│  ✓ Restart pods sequentially                │
│  ✓ Verify cluster health                    │
│  ✓ Monitor and self-heal                    │
│  ✓ Auto-detect environment profiles         │
└─────────────────────────────────────────────┘
```

## Quick Start

### 1. Upload Utilities to Cluster (One-time)

```powershell
# Upload apply-galera-timeouts.sh to pod-health-monitor
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action UploadUtilities

# Verify it's there
oc exec deployment/pod-health-monitor -n 950003-dev -- ls -lah /scripts/utils/
```

### 2. Apply Timeout Configuration (In-Cluster)

```powershell
# Auto-detect profile based on namespace and replica count
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action ApplyInCluster

# OR specify explicit profile
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-prod -Action ApplyInCluster -Profile production
```

### 3. Verify Configuration

```powershell
# Quick check from local machine
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Verify

# OR comprehensive in-cluster verification
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/apply-galera-timeouts.sh --verify-only
```

## Timeout Profiles

Profiles are defined in `config/mariadb/galera-timeout-profiles.yaml`:

| Profile | Use Case | inactive_timeout | Replicas | Environment |
|---------|----------|------------------|----------|-------------|
| `default` | Bitnami defaults | PT15S | Any | Low-latency only (⚠️ may cause split-brain in OpenShift) |
| `minimal` | Conservative change | PT30S | Any | Testing if timeout is root cause |
| `dev` | Development | PT20S | 2 | 950003-dev |
| `test` | Testing | PT25S | 3 | 950003-test |
| `production` | Production | PT30S | 5+ | 950003-prod |
| `full` | All parameters | PT30S + all tuning | 3+ | Proven split-brain issues |

**Auto-detection logic:**
- Dev namespace + 2 replicas → `dev` profile
- Test namespace + 3 replicas → `test` profile
- Prod namespace + 5+ replicas → `production` profile
- Fallback → `minimal` profile

## Architecture Details

### Configuration Priority (MariaDB)

1. **Command-line arguments** (HIGHEST) - `--wsrep-provider-options=...`
2. **Configuration file** (MEDIUM) - `my.cnf` wsrep_provider_options=
3. **Built-in defaults** (LOWEST) - Galera defaults (PT15S)

### Why my.cnf Instead of Helm?

| Approach | Pros | Cons | Verdict |
|----------|------|------|---------|
| **Helm `extraFlags`** | IaC compliant, version controlled | Complex quoting, `helm upgrade` failures, past issues | ⚠️ Theoretically best, practically difficult |
| **Direct env vars** | Fast, works | Helm may overwrite on upgrade | ⚠️ Good for emergency, not persistent |
| **ConfigMap my.cnf** | Simple, persistent, already managed | Lower priority than command-line | ✅ **RECOMMENDED** - Predictable and manageable |

**Decision:** Use ConfigMap my.cnf approach because:
- ✅ No command-line arguments set → my.cnf takes effect
- ✅ Already have scripts to manage it
- ✅ Integrated with right-sizing process
- ✅ Survives pod restarts automatically
- ✅ Helm creates ConfigMap but typically doesn't override wsrep settings we add

### In-Cluster Automation

**Script:** `config/pod-health-monitor/utils/apply-galera-timeouts.sh`

**Capabilities:**
- 🔍 Auto-detect appropriate profile based on namespace/replicas
- 📝 Update ConfigMap with timeout settings
- 🔄 Restart pods sequentially maintaining quorum
- ✅ Verify configuration applied correctly
- 🛡️ Health checks before/after changes
- 🔁 Idempotent (safe to run multiple times)

**Usage from within pod-health-monitor:**

```bash
# Auto-detect and apply
bash /scripts/utils/apply-galera-timeouts.sh --auto-detect

# Apply specific profile
bash /scripts/utils/apply-galera-timeouts.sh --profile production --namespace 950003-prod

# Verify only (no changes)
bash /scripts/utils/apply-galera-timeouts.sh --verify-only

# Dry-run to preview changes
bash /scripts/utils/apply-galera-timeouts.sh --profile test --dry-run
```

## Integration with Right-Sizing

Add Galera timeout profile to your sizing CSVs:

**openshift/950003-dev-sizing.csv:**
```csv
Component,Replicas,CPU,Memory,Storage,GaleraProfile
mariadb-galera,2,2000m,4Gi,50Gi,dev
```

**openshift/950003-prod-sizing.csv:**
```csv
Component,Replicas,CPU,Memory,Storage,GaleraProfile
mariadb-galera,5,8000m,16Gi,200Gi,production
```

When deploying a new environment, apply the appropriate profile:

```powershell
# Deploy infrastructure
oc apply -f openshift/mariadb-galera.yml -n 950003-prod

# Wait for pods to be ready
oc rollout status statefulset/mariadb-galera -n 950003-prod

# Apply timeout configuration
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-prod -Action ApplyInCluster -Profile production
```

## Monitoring and Verification

### Local Diagnostics (PowerShell)

```powershell
# Comprehensive diagnostics (all sources)
.\scripts\diagnose-galera-config-priority.ps1 -Namespace 950003-dev

# Quick verification
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Verify

# View logs
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action ShowLogs
```

### In-Cluster Monitoring

```bash
# From pod-health-monitor
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/galera-inspect.sh

# Verify timeout configuration
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/apply-galera-timeouts.sh --verify-only

# Check Galera cluster health
oc exec mariadb-galera-0 -n 950003-dev -- bash -c \
  'mysql -uroot -p$(cat $MARIADB_ROOT_PASSWORD_FILE) -e "SHOW STATUS LIKE \"wsrep%\";"'
```

## Troubleshooting

### Configuration Not Applying

**Symptom:** Runtime shows PT15S but ConfigMap shows PT30S

**Diagnosis:**
```powershell
.\scripts\diagnose-galera-config-priority.ps1 -Namespace 950003-dev
```

**Common causes:**
1. **Command-line args overriding** - Check for `MARIADB_EXTRA_FLAGS` environment variable
2. **Pods not restarted** - ConfigMap changes require pod restart
3. **Wrong ConfigMap** - Verify mariadb-galera-configuration (not mariadb-configuration)

**Fix:**
```bash
# Reapply configuration
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/apply-galera-timeouts.sh --profile dev
```

### Helm Overwriting ConfigMap

**Symptom:** Configuration reverts after `helm upgrade`

**Diagnosis:**
```bash
# Check Helm values
helm get values mariadb-galera -n 950003-dev
```

**Fix:** Add to Helm values.yaml:
```yaml
configuration: |
  [galera]
  wsrep_mode=REPLICATE_MYISAM
  wsrep_provider_options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S"
```

Then upgrade:
```bash
helm upgrade mariadb-galera bitnami/mariadb-galera -n 950003-dev -f values.yaml
```

### Split-Brain Still Occurring

**Symptom:** Pods going non-Primary despite PT30S timeout

**Diagnosis:**
```bash
# Check actual runtime timeout
oc exec mariadb-galera-0 -n 950003-dev -- bash -c \
  'mysql -uroot -p$(cat $MARIADB_ROOT_PASSWORD_FILE) -sN -e "SHOW VARIABLES LIKE \"wsrep_provider_options\";"' | grep inactive_timeout
```

**Possible causes:**
1. Configuration not actually applied (see above)
2. Network issues beyond timeout (e.g., complete network partition)
3. Resource exhaustion (CPU throttling, OOMKilled pods)
4. Insufficient replicas for quorum (2-node clusters vulnerable)

**Investigation:**
```powershell
# Check network latency between pods
.\scripts\measure-galera-network-latency.ps1 -Namespace 950003-dev

# Check resource usage
oc adm top pods -n 950003-dev -l app.kubernetes.io/name=mariadb-galera

# Check for OOM kills
oc get events -n 950003-dev | grep -i oom
```

## Best Practices

### ✅ DO:
- Use in-cluster automation (pod-health-monitor) for configuration changes
- Integrate timeout profiles with right-sizing process
- Test changes in dev before production
- Monitor for 24-48 hours after timeout changes
- Keep PowerShell scripts for diagnostics only
- Version control all configuration in repo

### ❌ DON'T:
- Edit ConfigMaps directly via `oc edit` (use scripts for traceability)
- Set aggressive timeouts (< PT15S) without thorough testing
- Deploy to production without dev/test validation
- Use 2-node clusters in production (minimum 3 for quorum)
- Forget to restart pods after ConfigMap changes
- Mix Helm extraFlags with ConfigMap settings (choose one approach)

## Related Documentation

- [Galera Timeout Tuning Strategy](galera-timeout-tuning-strategy.md) - Detailed timeout explanations
- [Production Split-Brain Testing Strategy](production-split-brain-testing-strategy.md) - Safe testing approach
- [Manual Galera Troubleshooting](manual-galera-troubleshooting.md) - Recovery procedures
- [Galera Monitoring Solution](galera-monitoring-solution.md) - Automated monitoring with pod-health-monitor

## Quick Reference Commands

```powershell
# === LOCAL OPERATIONS (PowerShell) ===

# Upload utilities to cluster
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action UploadUtilities

# Apply timeouts (delegates to in-cluster script)
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action ApplyInCluster

# Run diagnostics
.\scripts\diagnose-galera-config-priority.ps1 -Namespace 950003-dev

# Quick verify
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Verify

# === IN-CLUSTER OPERATIONS (bash) ===

# Auto-detect and apply
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/apply-galera-timeouts.sh --auto-detect

# Apply specific profile
oc exec deployment/pod-health-monitor -n 950003-prod -- \
  bash /scripts/utils/apply-galera-timeouts.sh --profile production

# Verify configuration
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/apply-galera-timeouts.sh --verify-only

# Check cluster health
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/galera-inspect.sh
```
