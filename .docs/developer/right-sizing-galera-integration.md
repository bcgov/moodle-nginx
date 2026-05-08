# Unified Right-Sizing + Galera Timeout Management

## Overview

This solution unifies resource management (CPU/memory/replicas) with Galera timeout configuration, enabling on-the-fly cluster tuning from a single CSV configuration file.

## Architecture

```
┌─────────────────────────────────────────────────┐
│  Developer Workstation (PowerShell)              │
│                                                  │
│  ./scripts/update-right-sizing.ps1 \            │
│    -Namespace 950003-dev \                       │
│    -CSVPath openshift/950003-dev-sizing.csv      │
│                                                  │
│  Actions:                                        │
│    1. Upload CSV to ConfigMap                    │
│    2. Trigger pod-health-monitor execution       │
│    3. Stream output back                         │
└───────────────────┬──────────────────────────────┘
                    │
                    │ Upload + Execute
                    │
                    v
┌─────────────────────────────────────────────────┐
│  OpenShift (pod-health-monitor)                  │
│                                                  │
│  bash /scripts/right-sizing.sh                  │
│                                                  │
│  Executes:                                       │
│    1. Read CSV from ConfigMap                    │
│    2. Apply CPU/memory limits                   │
│    3. Scale pods (incremental for Galera)       │
│    4. Apply Galera timeout profiles             │
│    5. Verify cluster health                     │
│    6. Create HPAs                               │
└─────────────────────────────────────────────────┘
```

## Quick Start

### 1. Prepare CSV with Galera Profile

Edit your sizing CSV (e.g., `openshift/950003-dev-sizing.csv`):

```csv
Deployment,Type,Pod Count,Max Pods,PVC Count,PVC Capacity (MiB),CPU Request (m),CPU Limit (m),Mem. Request (MiB),Mem. Limit (MiB),CPU Scale Value,Galera Profile
php,deployment,1,1,1,1024,80,1500,128,0,400,
mariadb-galera,sts,2,2,2,7168,60,0,256,0,0,dev
redis-node,sts,1,1,1,3072,50,0,128,0,100,
```

**Key:**
- **New column:** `Galera Profile` (12th column)
- **Values:** `default`, `minimal`, `dev`, `test`, `production`, `full`, or empty (skip)
- **Only applies to:** StatefulSets with Galera in the name

### 2. Upload Utilities to Cluster (One-Time)

```powershell
# Ensure apply-galera-timeouts.sh is in pod-health-monitor
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action UploadUtilities
```

### 3. Apply Right-Sizing + Galera Tuning

```powershell
# Upload CSV and trigger in-cluster execution
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev

# Or with custom CSV
.\scripts\update-right-sizing.ps1 -Namespace 950003-test -CSVPath openshift\custom-sizing.csv

# Only right-size specific deployments (safe for production database changes)
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod -Deployments mariadb-galera

# Right-size multiple specific deployments
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev -Deployments mariadb-galera,php,web

# Preview changes without applying
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod -DryRun
```

### 3a. Upload Custom my.cnf Configuration (Optional)

The script auto-detects environment-specific my.cnf files:
- `config/mariadb/<namespace>.cnf` (first priority)
- `config/mariadb/my.cnf` (fallback)

```powershell
# Auto-detect environment-specific config
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod
# Uploads: config/mariadb/950003-prod.cnf (with PT30S timeouts)

# Or manually specify custom my.cnf
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev -MyCNF config\mariadb\my-test-PT25S.cnf

# Skip my.cnf upload (CSV-only update)
.\scripts\update-right-sizing.ps1 -Namespace 950003-test -SkipMyCNF
```

**Environment-Specific Configs:**

| File | Timeout Profile | Use Case |
|------|----------------|----------|
| `config/mariadb/950003-dev.cnf` | PT20S | Development cluster (2 replicas) |
| `config/mariadb/950003-test.cnf` | PT25S | Test cluster (3 replicas) |
| `config/mariadb/950003-prod.cnf` | PT30S | Production cluster (5+ replicas) |
| `config/mariadb/my.cnf` | *(no timeouts)* | Baseline config (not recommended) |

**What Gets Uploaded:**
- **ConfigMap Name:** `mariadb-galera-configuration`
- **Mount Path:** `/opt/bitnami/mariadb/conf/my.cnf`
- **Restart Required:** Yes (pods restart automatically after ConfigMap update)
- **Helm Integration:** Labels/annotations match `deploy-mariadb-galera.sh` pattern

### 4. Verify Configuration

```bash
# Check pod status
oc get pods -n 950003-dev

# Verify Galera timeout configuration
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/apply-galera-timeouts.sh --verify-only

# Check Galera cluster health
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash /scripts/utils/galera-inspect.sh
```

## CSV Format (12 Columns)

| Column | Example | Description |
|--------|---------|-------------|
| 1. Deployment | `mariadb-galera` | Resource name |
| 2. Type | `sts` or `deployment` | Resource type |
| 3. Pod Count | `2` | Target replica count |
| 4. Max Pods | `2` | Maximum for HPA (0 = no HPA) |
| 5. PVC Count | `2` | Persistent volume claims |
| 6. PVC Capacity (MiB) | `7168` | PVC size in MiB |
| 7. CPU Request (m) | `60` | CPU request in millicores |
| 8. CPU Limit (m) | `0` | CPU limit (0 = burst enabled) |
| 9. Mem. Request (MiB) | `256` | Memory request |
| 10. Mem. Limit (MiB) | `0` | Memory limit (0 = burst enabled) |
| 11. CPU Scale Value | `0` | HPA target CPU % (0 = no HPA) |
| 12. **Galera Profile** | `dev` | Timeout profile (empty = skip) |

**Galera Profile Values:**

| Profile | inactive_timeout | Use Case |
|---------|------------------|----------|
| `default` | PT15S | Restore Bitnami defaults (⚠️ may cause split-brain) |
| `minimal` | PT30S | Conservative - only adjust inactive_timeout |
| `dev` | PT20S | 2-replica dev environment |
| `test` | PT25S | 3-replica test environment |
| `production` | PT30S | 5+ replica production with flow control |
| `full` | PT30S | All tuning parameters |
| *(empty)* | (skip) | No Galera tuning applied |

## Workflow

### Local Development Workflow

```powershell
# 1. Edit CSV locally
code openshift\950003-dev-sizing.csv

# 2. Test changes (adjust mariadb CPU/memory, Galera profile)
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev

# 3. Monitor results
oc get pods -n 950003-dev -w

# 4. Verify Galera cluster
oc exec deployment/pod-health-monitor -n 950003-dev -- bash /scripts/utils/galera-inspect.sh

# 5. If successful, commit CSV changes
git add openshift\950003-dev-sizing.csv
git commit -m "feat: adjust dev cluster sizing and Galera timeouts"
```

### Production Deployment Workflow

```powershell
# 1. Test in dev/test first
.\scripts\update-right-sizing.ps1 -Namespace 950003-test

# 2. Monitor for 24-48 hours (no split-brain, performance OK)

# 3. Apply to production
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod

# 4. Monitor production
oc logs -l app.kubernetes.io/name=mariadb-galera -n 950003-prod --tail=100 -f

# 5. Verify no split-brain for 7+ days
```

## Use Cases

### Squeeze Another Pod into Dev

**Scenario:** Dev has 2 MariaDB pods, need to test with 3

```csv
# Before
mariadb-galera,sts,2,2,2,7168,60,0,256,0,0,dev

# After - reduce CPU/memory per pod, increase count
mariadb-galera,sts,3,3,3,7168,40,0,192,0,0,test
```

```powershell
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev
```

**Result:**
- Scales from 2 → 3 pods incrementally (maintains quorum)
- Applies PT25S timeout (test profile)
- Reduces CPU 60→40m, memory 256→192Mi per pod
- Total resources fit within namespace quota

### Fix Production Split-Brain

**Scenario:** Production experiencing recurring split-brain from PT15S defaults

**Root Cause:** Bitnami default `evs.inactive_timeout=PT15S` too aggressive for 5-pod production cluster

**Solution:** Deploy environment-specific my.cnf with PT30S timeout profile

```powershell
# 1. Verify environment-specific config exists
cat config\mariadb\950003-prod.cnf | Select-String "wsrep_provider_options"
# Should show: evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;...

# 2. Test in dev first
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev
# Uploads config/mariadb/950003-dev.cnf (PT20S profile)

# 3. Apply to production
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod
# Auto-detects and uploads config/mariadb/950003-prod.cnf (PT30S profile)

# 4. Verify ConfigMap updated
oc get configmap mariadb-galera-configuration -n 950003-prod -o yaml | Select-String "inactive_timeout"
# Should show: evs.inactive_timeout=PT30S

# 5. Monitor logs during pod restart
oc logs -l app.kubernetes.io/name=mariadb-galera -n 950003-prod --tail=100 -f

# 6. Verify Galera picks up new timeouts
oc exec mariadb-galera-0 -n 950003-prod -- \
  mysql -e "SHOW VARIABLES LIKE 'wsrep_provider_options';" | Select-String "inactive_timeout"

# 7. Monitor for 7+ days - no split-brain should occur
```

**Alternative: Test Custom Timeout First**

If uncertain about PT30S, test variations before committing:

```powershell
# Create test config with PT35S
Copy-Item config\mariadb\950003-prod.cnf config\mariadb\my-test-PT35S.cnf
# Edit wsrep_provider_options to use PT35S

# Apply test config
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod -MyCNF config\mariadb\my-test-PT35S.cnf

# Monitor for 24-48 hours
# If stable, commit as production config:
Move-Item -Force config\mariadb\my-test-PT35S.cnf config\mariadb\950003-prod.cnf
git commit -am "feat: finalize production Galera timeout at PT35S"
```

```powershell
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod
```

**Result:**
- Applies PT30S timeout with flow control
- No pod scaling (count unchanged)
- Resources unchanged
- Rolling restart maintains quorum
- Split-brain issues resolved

### Test Minimal Impact

**Scenario:** Uncertain if timeout is root cause

```csv
mariadb-galera,sts,2,2,2,7168,60,0,256,0,0,minimal
```

```powershell
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev
```

**Result:**
- Only changes `evs.inactive_timeout` to PT30S
- All other Galera settings unchanged
- Conservative approach for testing
- Can expand to `full` profile if successful

## In-Cluster Execution

The right-sizing script can also be executed directly in the cluster (useful for automation):

```bash
# From within pod-health-monitor
export DEPLOY_NAMESPACE="950003-dev"
export CSV_SOURCE="configmap"
bash /scripts/right-sizing.sh

# Or via oc exec
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash -c 'export DEPLOY_NAMESPACE=950003-dev; export CSV_SOURCE=configmap; bash /scripts/right-sizing.sh'
```

## Integration with CI/CD

Add to your deployment pipeline:

```yaml
# .github/workflows/deploy-dev.yml
- name: Apply Right-Sizing Configuration
  run: |
    ./scripts/update-right-sizing.ps1 -Namespace 950003-dev
  shell: pwsh
```

This ensures every deployment applies the correct resource allocation and Galera tuning automatically.

## Troubleshooting

### CSV Not Being Applied

**Symptom:** Script completes but no changes observed

**Check:**
```powershell
# Verify ConfigMap was created
oc get configmap right-sizing-config -n 950003-dev

# View ConfigMap content
oc get configmap right-sizing-config -n 950003-dev -o yaml

# Check CSV format
oc get configmap right-sizing-config -n 950003-dev -o jsonpath='{.data.sizing\.csv}'
```

### Galera Profile Not Applied

**Symptom:** Right-sizing completes but Galera timeouts unchanged

**Check:**
```bash
# Verify apply-galera-timeouts.sh exists in pod
oc exec deployment/pod-health-monitor -n 950003-dev -- ls -lah /scripts/utils/

# Check if profile was detected
oc logs deployment/pod-health-monitor -n 950003-dev --tail=100 | grep "Galera"

# Manually verify timeout
oc exec mariadb-galera-0 -n 950003-dev -- bash -c \
  'mysql -uroot -p$(cat $MARIADB_ROOT_PASSWORD_FILE) -sN -e "SHOW VARIABLES LIKE \"wsrep_provider_options\";"' | grep inactive_timeout
```

**Fix:**
```powershell
# Upload utilities if missing
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action UploadUtilities

# Rerun right-sizing
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev
```

### Script Execution Fails

**Symptom:** `update-right-sizing.ps1` returns error

**Check:**
```powershell
# Verify pod-health-monitor is running
oc get deployment pod-health-monitor -n 950003-dev

# Check pod logs for errors
oc logs deployment/pod-health-monitor -n 950003-dev --tail=50

# Test manual execution
oc exec deployment/pod-health-monitor -n 950003-dev -- \
  bash -c 'export DEPLOY_NAMESPACE=950003-dev; export CSV_SOURCE=configmap; bash /scripts/right-sizing.sh'
```

## Best Practices

### ✅ DO:
- Test CSV changes in dev before production
- Version control all CSV files
- Monitor for 24-48 hours after changes
- Use `minimal` profile first when testing
- Document why specific profiles were chosen
- Commit CSV changes with descriptive messages

### ❌ DON'T:
- Apply untested profiles directly to production
- Edit CSV while right-sizing is running
- Use `default` profile in production (PT15S too aggressive)
- Scale down Galera without proper quorum planning
- Forget to monitor for split-brain after changes
- Mix manual `oc scale` with CSV-based right-sizing

## Files

- **PowerShell:** `scripts/update-right-sizing.ps1` - Local orchestrator with my.cnf upload
- **Bash:** `openshift/scripts/right-sizing.sh` - In-cluster execution
- **CSV:** `openshift/<namespace>-sizing.csv` - Resource configuration files
- **my.cnf:** `config/mariadb/<namespace>.cnf` - Environment-specific database configs
- **ConfigMap:** `right-sizing-config` - In-cluster CSV storage
- **ConfigMap:** `mariadb-galera-configuration` - my.cnf storage (ConfigMap mount)

## Related Documentation

- [Galera Timeout Reference](galera-timeout-reference.md) - Timeout parameter documentation
- [Galera Timeout Tuning Strategy](galera-timeout-tuning-strategy.md) - Profile details and tradeoffs
- [Production Split-Brain Testing Strategy](production-split-brain-testing-strategy.md) - Safe testing approach
- [Manual Galera Troubleshooting](manual-galera-troubleshooting.md) - Recovery procedures

## Summary

This unified approach provides:
- 🎯 **Single source of truth** - One CSV file controls resources + Galera tuning
- ☁️ **Cloud-native** - All changes applied within cluster
- 🔄 **Integrated workflow** - Right-sizing naturally includes Galera optimization
- 🛡️ **Safe execution** - Incremental Galera scaling, quorum maintenance
- ⚡ **Developer friendly** - Simple PowerShell command for all environments
- 📊 **Version controlled** - CSV files in Git = full change history

**Production split-brain fix is now as simple as:**
```powershell
# 1. Edit CSV: add "production" to Galera Profile column
# 2. Apply
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod
# 3. Monitor - split-brain should not recur
```
