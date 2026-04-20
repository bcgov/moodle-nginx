# 🛠️ Local Development Scripts

This directory contains PowerShell scripts to assist with **local development tasks** on Windows environments. These scripts provide immediate feedback and validation before committing changes or running CI/CD pipelines.

## 🏗️ Architecture Philosophy

**Cloud-Native Approach:** Heavy lifting happens IN the cluster, PowerShell focuses on diagnostics and setup.

```
┌─────────────────┐         ┌──────────────────────┐
│  PowerShell     │         │  In-Cluster          │
│  (Local)        │────────▶│  (pod-health-monitor)│
│                 │         │                      │
│  • Diagnostics  │         │  • Config updates    │
│  • Upload utils │         │  • Pod restarts      │
│  • Trigger ops  │         │  • Health checks     │
│  • View logs    │         │  • Auto-healing      │
└─────────────────┘         └──────────────────────┘
```

**See:** [Galera Timeout In-Cluster Architecture](../docs/galera-timeout-in-cluster-architecture.md)

---

## 📋 Available Scripts

### 🔧 Galera Cluster Management

#### `check-galera-cluster-address.ps1` - Detect & Fix Cluster Address Issues (🚨 CRITICAL FOR SPLIT-BRAIN PREVENTION)

**Purpose:** Diagnose and fix MARIADB_GALERA_CLUSTER_ADDRESS misconfiguration that causes nodes to bootstrap independently

**Architecture:** Thin PowerShell wrapper → Calls in-cluster bash script via pod-health-monitor

**When to Use:**
- ❌ Nodes 1-4 bootstrap independently instead of joining node 0
- ❌ Each pod has a different cluster UUID (split-brain)
- ❌ `MARIADB_GALERA_CLUSTER_ADDRESS` is not set, empty, or set to `gcomm://`
- ✅ After bootstrap recovery to ensure proper cluster discovery
- ✅ Before scaling up to prevent split-brain
- ✅ Integrated into auto-heal workflow (runs automatically)

**Usage:**
```powershell
# Diagnostic mode (check only)
.\scripts\check-galera-cluster-address.ps1 -Namespace 950003-prod

# Apply fixes automatically
.\scripts\check-galera-cluster-address.ps1 -Namespace 950003-prod -Fix
```

**What It Checks:**
1. `MARIADB_GALERA_CLUSTER_ADDRESS` - Must be `gcomm://pod-0.headless,pod-1.headless,...`
2. `MARIADB_GALERA_CLUSTER_BOOTSTRAP` - Must be `no` (except during recovery)
3. `MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP` - Must be `no` (except during recovery)

**Root Cause:** database.sh Step 7 removed the cluster address instead of setting it, preventing cluster discovery.

**In-Cluster Implementation:** [openshift/scripts/utils/galera-fix-cluster-address.sh](../openshift/scripts/utils/galera-fix-cluster-address.sh)
**Documentation:** [Manual Galera Troubleshooting](../docs/manual-galera-troubleshooting.md)

---

#### `galera-recovery-step.ps1` - Step-by-Step Galera Recovery (🔍 DEBUGGING)

**Purpose:** Run individual `galera_safe_upgrade()` steps for debugging and validation

**Architecture:** Sets `GALERA_FROM_STEP` / `GALERA_TO_STEP` env vars, execs into pod-health-monitor

**Usage:**
```powershell
# Show cluster status + step reference table
.\scripts\galera-recovery-step.ps1 -Status -Namespace 950003-test

# Run only step 7 (partition + disable bootstrap)
.\scripts\galera-recovery-step.ps1 -Step 7 -Namespace 950003-test

# Run steps 7-8 (partition through scale-out)
.\scripts\galera-recovery-step.ps1 -FromStep 7 -ToStep 8 -Namespace 950003-test

# Resume from step 8 to end
.\scripts\galera-recovery-step.ps1 -FromStep 8 -Namespace 950003-test

# Full recovery (all steps)
.\scripts\galera-recovery-step.ps1 -Full -Namespace 950003-test
```

**Steps:**
| Step | Phase | Description |
|------|-------|-------------|
| 1 | Pre-flight | Verify galera-0 safe + save annotation |
| 2 | Teardown | Scale to 0, clear EXTRA_FLAGS |
| 3 | PVC Prep | Delete secondary PVCs, fix grastate.dat |
| 4 | Bootstrap | Set bootstrap=yes env vars |
| 5 | Primary Up | Scale to 1, wait galera-0 Ready |
| 7 | Partition | Partition=1, bootstrap=no, verify Primary |
| 8 | Scale Out | Scale to target + deadlock detection |
| 9 | Finalize | Wait sync, remove partition, health check |

**When to Use:**
- ✅ Recovery failed at a specific step — re-run just that step
- ✅ Validate each phase before proceeding to the next
- ✅ Debug partition/bootstrap interactions without full 5-minute cycle

---

#### `emergency-galera-recovery.ps1` - Full Emergency Recovery

**Purpose:** Execute full `galera_safe_upgrade()` via pod-health-monitor when all pods are crashing

**Usage:**
```powershell
.\scripts\emergency-galera-recovery.ps1 -Namespace 950003-test
.\scripts\emergency-galera-recovery.ps1 -Namespace 950003-prod -TargetReplicas 5
.\scripts\emergency-galera-recovery.ps1 -Namespace 950003-dev -DryRun
```

---

#### `update-right-sizing.ps1` - Unified Right-Sizing + Galera Tuning (⭐ RECOMMENDED FOR PRODUCTION)

**Purpose:** Upload right-sizing CSV + my.cnf configuration, trigger in-cluster execution

**Usage:**
```powershell
# Auto-detect CSV and environment-specific my.cnf
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev
# Uploads: openshift/950003-dev-sizing.csv + config/mariadb/950003-dev.cnf

# Specify custom CSV
.\scripts\update-right-sizing.ps1 -Namespace 950003-test -CSVPath openshift\custom-sizing.csv

# Specify custom my.cnf
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod -MyCNF config\mariadb\my-test-PT35S.cnf

# Skip my.cnf upload (CSV-only update)
.\scripts\update-right-sizing.ps1 -Namespace 950003-test -SkipMyCNF

# Preview changes without applying
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod -DryRun
```

**What it does:**
- Uploads CSV to ConfigMap `right-sizing-config`
- Uploads my.cnf to ConfigMap `mariadb-galera-configuration` (auto-detected or manual)
- Triggers `openshift/scripts/right-sizing.sh` in pod-health-monitor
- Applies CPU/memory limits, pod scaling
- Restarts MariaDB pods to pick up new my.cnf
- Creates HPAs where configured
- Maintains quorum during changes

**Auto-Detection Logic:**
1. **CSV:** `openshift/<namespace>-sizing.csv` → error if not found
2. **my.cnf:** `config/mariadb/<namespace>.cnf` → `config/mariadb/my.cnf` → warn if neither found

**Environment-Specific Configs:**
| File | Timeout Profile | Use Case |
|------|----------------|----------|
| `config/mariadb/950003-dev.cnf` | PT20S | Development (2 replicas) |
| `config/mariadb/950003-test.cnf` | PT25S | Test (3 replicas) |
| `config/mariadb/950003-prod.cnf` | PT30S | Production (5+ replicas) |

**Use Cases:**
- ✅ Fix production split-brain (upload PT30S my.cnf)
- ✅ Test custom timeout profiles (use -MyCNF parameter)
- ✅ Squeeze another pod into dev (adjust CSV + my.cnf)
- ✅ Unified deployment of resources + Galera config

**Documentation:** [Right-Sizing + Galera Integration](../docs/right-sizing-galera-integration.md)

---

#### `manage-galera-utilities.ps1` - In-Cluster Automation Manager

**Purpose:** Upload utilities to cluster, run diagnostics, trigger in-cluster operations

**Usage:**
```powershell
# Upload utility scripts to pod-health-monitor (one-time)
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action UploadUtilities

# Apply timeout configuration (auto-detect profile)
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-prod -Action ApplyInCluster

# Apply with specific profile
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-test -Action ApplyInCluster -Profile test

# Run diagnostics
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Diagnose

# Quick verification
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Verify

# View pod-health-monitor logs
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-prod -Action ShowLogs
```

**Documentation:** [In-Cluster Architecture](../docs/galera-timeout-in-cluster-architecture.md)

---

#### `diagnose-galera-config-priority.ps1` - Configuration Source Diagnostics

**Purpose:** Comprehensive diagnostics of all Galera configuration sources

**What it checks:**
- ✅ Helm values (extraFlags)
- ✅ Environment variables (MARIADB_EXTRA_FLAGS)
- ✅ ConfigMap (my.cnf)
- ✅ Runtime MySQL configuration
- ✅ Configuration conflicts and priority issues

**Usage:**
```powershell
# Run full diagnostic
.\scripts\diagnose-galera-config-priority.ps1 -Namespace 950003-dev
```

**Use when:**
- Configuration not applying as expected
- Runtime timeout doesn't match ConfigMap
- Investigating Helm vs manual config conflicts

---

#### `deploy-galera-timeouts.ps1` - Direct Deployment (Legacy)

**Purpose:** Deploy Galera timeout configuration to prevent split-brain events

**⚠️ Note:** Consider using `manage-galera-utilities.ps1` for in-cluster approach instead

**Usage:**
```powershell
# Deploy with environment-specific profile
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Dev
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod

# Restore original defaults (after testing)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Default

# Preview changes without applying
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -WhatIf
```

**Available Profiles:**

| Profile | Timeout | Use Case | Documentation |
|---------|---------|----------|---------------|
| `Default` | PT15S | Restore Bitnami defaults | [Tuning Strategy](../docs/galera-timeout-tuning-strategy.md#default) |
| `Dev` | PT20S | 2-replica dev environments | [Tuning Strategy](../docs/galera-timeout-tuning-strategy.md#dev) |
| `Test` | PT25S | 3-replica test environments | [Tuning Strategy](../docs/galera-timeout-tuning-strategy.md#test) |
| `Prod` | PT30S | 5-replica production | [Tuning Strategy](../docs/galera-timeout-tuning-strategy.md#prod) |
| `Minimal` | PT30S | Conservative change (inactive_timeout only) | [Tuning Strategy](../docs/galera-timeout-tuning-strategy.md#minimal) |
| `Full` | All 7 | Comprehensive tuning (default) | [Tuning Strategy](../docs/galera-timeout-tuning-strategy.md#full) |

**Documentation:** [Galera Timeout Tuning Strategy](../docs/galera-timeout-tuning-strategy.md)

---

#### `bootstrap-mariadb-galera.ps1` - Disaster Recovery

**Purpose:** Recover MariaDB Galera cluster from split-brain or complete outage

**Usage:**
```powershell
# Analyze cluster state (safe, read-only)
.\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-prod -Analyze

# Execute bootstrap recovery
.\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-prod -Bootstrap

# Force bootstrap from specific node (override automatic selection)
.\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-prod -Bootstrap -BootstrapNode mariadb-galera-2
```

**Features:**
- Analyzes grastate.dat (seqno) from all nodes
- Identifies node with highest seqno (most recent data)
- **Auto-detects and fixes MARIADB_GALERA_CLUSTER_ADDRESS via in-cluster script**
- Guides safe bootstrap process with validation
- Handles edge cases (all seqno=-1, conflicting flags)
- Scales StatefulSet: 0→1→2→...→N with sync validation

**⚠️ WARNING:** High-risk operation. Always run `-Analyze` first.

**Integrated Checks:** Automatically calls [check-galera-cluster-address.ps1](#check-galera-cluster-addressps1) before scale-up.

**Documentation:** [Production Split-Brain Testing Strategy](../docs/production-split-brain-testing-strategy.md)

---

#### `scale-galera.sh` - Safe Manual Scaling (⚠️ Use Instead of `oc scale`)

**Purpose:** Provides safe Galera-aware wrapper around `oc scale` to prevent split-brain during manual operations

**Architecture:** Bash script → Calls scale_galera_statefulset() from openshift.sh

**When to Use:**
- ✅ Manual scaling operations (increase/decrease replica count)
- ✅ Scale-up with incremental sync validation
- ✅ Scale-down with OrderedReady protection
- ✅ Pre-flight cluster address verification

**⚠️ NEVER Use These Commands Directly:**
```bash
❌ oc scale sts/mariadb-galera --replicas=5          # Bypasses all protections
❌ oc delete pod mariadb-galera-{1,2,3,4}            # Parallel restart causes split-brain
❌ oc delete pvc data-mariadb-galera-*               # Data loss + wrong bootstrap
❌ oc rollout restart sts/mariadb-galera             # Parallel restart
```

**✅ ALWAYS Use:**
```bash
# Scale mariadb-galera to 5 replicas (current namespace)
./scripts/scale-galera.sh mariadb-galera --replicas=5

# Scale in specific namespace
./scripts/scale-galera.sh mariadb-galera --replicas=3 --namespace=e66ac2-prod

# For emergencies, use full bootstrap recovery
./scripts/bootstrap-mariadb-galera.ps1 -Bootstrap
```

**Features:**
- Pre-flight cluster address verification (prevents split-brain)
- Incremental scale-up (1→2→3→...→N) with sync validation per node
- Safe scale-down (leverages OrderedReady for reverse shutdown)
- Comprehensive health checks (wsrep status, cluster UUID verification)
- Interactive confirmation prompts for safety

**Integration:**
- Used by: right-sizing.sh (automated deployments)
- Called by: scale_galera_statefulset() in openshift.sh
- Documented in: [Galera Deployment Best Practices](../docs/galera-deployment-best-practices.md#solution-5)

**Documentation:** [Galera Deployment Best Practices](../docs/galera-deployment-best-practices.md)

---

#### `measure-galera-network-latency.ps1` - Network Analysis

**Purpose:** Measure actual network latency between Galera pods to diagnose timeout issues

**Usage:**
```powershell
# Measure latency in dev
.\scripts\measure-galera-network-latency.ps1 -Namespace 950003-dev

# Measure latency in prod (compare with dev)
.\scripts\measure-galera-network-latency.ps1 -Namespace 950003-prod
```

**Features:**
- Tests MySQL connection latency (Galera communication path)
- Tests port 4567 connectivity (Galera replication port)
- Calculates average, min, max latency
- Recommends timeout profile based on measurements
- Helps distinguish network vs resource contention issues

**Use Cases:**
- Determine if network latency explains split-brain
- Compare dev vs prod network characteristics
- Validate timeout profile selection
- Baseline measurement before testing

**Documentation:** [Production Split-Brain Testing Strategy](../docs/production-split-brain-testing-strategy.md#phase-1-baseline-measurement-no-risk)

---

### 🔧 Pod Health Monitor Management

#### `update-pod-health-scripts.ps1`

**Related Documentation:**
- Configuration reference: [config/mariadb/galera-timeouts.yaml](../config/mariadb/galera-timeouts.yaml)
- Root cause analysis: [docs/galera-split-brain-rca.md](../docs/galera-split-brain-rca.md)
- Diagnostic script: [openshift/scripts/galera-inspect.sh](../openshift/scripts/galera-inspect.sh)

---

#### `update-pod-health-scripts.ps1`

Deploy or update pod-health-monitor scripts and utilities in OpenShift. Updates ConfigMaps with bash utilities and diagnostic scripts.

**Usage:**
```powershell
# Update all scripts in dev environment
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev

# Update only monitoring script
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev -ScriptType Monitor

# Update only utilities (includes galera diagnostic scripts)
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev -ScriptType Utils

# Update ConfigMaps only, skip pod restart
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev -SkipRestart
```

**Features:**
- Validates OpenShift authentication and namespace access
- Normalizes line endings (CRLF → LF) for Linux compatibility
- Creates or updates ConfigMaps: `pod-health-monitor-script`, `check-pod-logs-script`
- Deploys utilities: `_utils.sh`, database/redis/openshift/moodle helpers
- Deploys Galera diagnostic scripts: `galera-inspect.sh`, `galera-recover.sh`
- Automatically restarts pod-health-monitor to apply changes
- Provides usage examples for diagnostic operations

**Script Types:**

| Type | ConfigMap | Contains |
|------|-----------|----------|
| `All` | Both ConfigMaps | All scripts and utilities (default) |
| `Monitor` | pod-health-monitor-script | monitor-pods.sh only |
| `Utils` | check-pod-logs-script | Utilities, galera scripts, helper functions |

**Related Documentation:**
- Utility integration: [docs/pod-health-monitor-utilities.md](../docs/pod-health-monitor-utilities.md)
- Bash utilities: [openshift/scripts/_utils.sh](../openshift/scripts/_utils.sh)
- Galera diagnostics: [openshift/scripts/galera-inspect.sh](../openshift/scripts/galera-inspect.sh)

---

### 🔒 Security Scanning

#### `local-dev-security-scan.ps1`

Performs comprehensive security scanning of Docker images using **Docker Scout** (local development tool).

**Usage:**
```powershell
# Basic scan (default: MEDIUM and above)
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-php:latest"

# Scan with specific severity threshold
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-php:latest" -MinSeverity "HIGH"

# Generate JSON report
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-php:latest" -OutputFormat "json"

# Scan with recommendations
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-php:latest" -ShowRecommendations
```

**Features:**
* ✅ Automatic validation (Docker, Docker Scout, image availability)
* ✅ Severity filtering (LOW/MEDIUM/HIGH/CRITICAL)
* ✅ Multiple output formats (table/json/sarif/markdown)
* ✅ Remediation recommendations
* ✅ Color-coded console output

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ImageName` | String | *(required)* | Docker image to scan |
| `MinSeverity` | String | `MEDIUM` | Minimum severity to report |
| `OutputFormat` | String | `table` | Output format (table/json/sarif/markdown) |
| `ShowRecommendations` | Switch | `false` | Display remediation recommendations |

**See Also:**

* [Security Scanning Guide](../.docs/security-scanning.md)
* [Vulnerability Exception Management](../.docs/vulnerability-exceptions.md)

---

### 🔄 Version Management

#### `local-validate-version-consistency.ps1`

Validates compatibility between infrastructure versions (`example.versions.env`) and application dependency constraints (`composer.json`, `package.json`).

**Usage:**
```powershell
# Basic validation
.\scripts\local-validate-version-consistency.ps1

# Generate detailed report
.\scripts\local-validate-version-consistency.ps1 -ShowReport

# For pre-commit hooks (exits with error code)
.\scripts\local-validate-version-consistency.ps1 -ExitOnError

# Quiet mode (minimal output)
.\scripts\local-validate-version-consistency.ps1 -Quiet
```

**Features:**
* ✅ Validates PHP runtime vs Composer constraints
* ✅ Validates Node runtime vs NPM constraints
* ✅ Checks lock file consistency
* ✅ Generates detailed markdown reports
* ✅ Immediate local feedback (no need to wait for CI/CD)

**Parameters:**

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `ProjectRoot` | String | *(auto)* | Project root directory |
| `ShowReport` | Switch | `false` | Generate and open detailed report |
| `ExitOnError` | Switch | `false` | Exit with non-zero code on failure |
| `Quiet` | Switch | `false` | Minimal output (errors only) |

**See Also:**

* [Centralized Dependency Management](../.docs/centralized-dependency-management.md)
* [Version Management Architecture](../.docs/diagrams/version-management-architecture.md)

---

## 🎯 Common Workflows

### Pre-Commit Validation

Before committing changes that affect versions:

```powershell
# Validate version consistency
.\scripts\local-validate-version-consistency.ps1

# If using Docker images, scan for vulnerabilities
docker build -t moodle-php:local .
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-php:local" -MinSeverity "HIGH"
```

### Infrastructure Version Update

When updating PHP, Node, or other infrastructure versions:

```powershell
# 1. Edit example.versions.env
notepad example.versions.env

# 2. Validate compatibility
.\scripts\local-validate-version-consistency.ps1 -ShowReport

# 3. Update application constraints if needed
notepad config\moodle\composer.json

# 4. Re-validate
.\scripts\local-validate-version-consistency.ps1
```

### Application Dependency Update

When updating Composer or NPM dependencies:

```powershell
# 1. Update composer.json or package.json
cd config\moodle
composer update

# 2. Validate infrastructure compatibility
cd ..\..
.\scripts\local-validate-version-consistency.ps1

# 3. Update infrastructure if mismatch detected
notepad example.versions.env
```

### Security Audit Before Release

Before deploying to production:

```powershell
# Build images
docker-compose build

# Scan all images
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-php:latest" -MinSeverity "HIGH" -ShowRecommendations
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-nginx:latest" -MinSeverity "HIGH" -ShowRecommendations
```

---

### Galera Split-Brain Prevention

When experiencing recurring Galera split-brain events:

```powershell
# 1. Diagnose current configuration
oc exec deployment/pod-health-monitor -n 950003-dev -- bash /scripts/utils/galera-inspect.sh

# 2. Deploy recommended timeout configuration
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev

# 3. Monitor for improvements
oc logs deployment/pod-health-monitor -n 950003-dev -f | Select-String "galera"
```

### Galera Recovery Workflow

If cluster is in split-brain state:

```powershell
# 1. Inspect cluster status
oc exec deployment/pod-health-monitor -n 950003-dev -- bash /scripts/utils/galera-inspect.sh

# 2. If split-brain detected, recover cluster
oc exec -it deployment/pod-health-monitor -n 950003-dev -- bash /scripts/utils/galera-recover.sh

# 3. After recovery, deploy timeout fix to prevent recurrence
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev
```

### Update Diagnostic Scripts

When modifying Galera diagnostic or utility scripts:

```powershell
# 1. Update scripts in dev environment
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev -ScriptType Utils

# 2. Test diagnostic script
oc exec deployment/pod-health-monitor -n 950003-dev -- bash /scripts/utils/galera-inspect.sh

# 3. If working correctly, deploy to test and production
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-test -ScriptType Utils
.\scripts\update-pod-health-scripts.ps1 -Namespace 950003-prod -ScriptType Utils
```
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-cron:latest" -MinSeverity "HIGH" -ShowRecommendations

# Validate versions
.\scripts\local-validate-version-consistency.ps1 -ShowReport
```

---

## 🔧 Setup & Requirements

### Prerequisites

**All Scripts:**
* Windows 10/11
* PowerShell 5.1 or higher

**Security Scanning:**
* Docker Desktop installed and running
* Docker Scout CLI installed (see below)

**Version Validation:**
* No additional requirements (pure PowerShell)

### Installing Docker Scout

Docker Scout is included with Docker Desktop but may need to be enabled:

1. **Install Docker Desktop** (if not already installed)
   * Download: <https://www.docker.com/products/docker-desktop>

2. **Enable Docker Scout**
   ```powershell
   # Check if Scout is available
   docker scout version

   # If not available, install via Docker Desktop:
   # Settings → Extensions → Browse → Search "Docker Scout" → Install
   ```

3. **Verify Installation**
   ```powershell
   docker scout version
   # Should show: Docker Scout version X.Y.Z
   ```

### Execution Policy

If scripts won't run due to execution policy:

```powershell
# Check current policy
Get-ExecutionPolicy

# Allow scripts (run as Administrator)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# Or bypass for single execution
PowerShell -ExecutionPolicy Bypass -File .\scripts\local-validate-version-consistency.ps1
```

---

## 📊 Understanding Output

### Version Validation Output

```
🔍 Version Consistency Validation (Local)
================================================================================

🏗️  Infrastructure Versions
================================================================================
ℹ️  PHP Runtime
   8.1 (from bitnami/php-fpm:8.1.31-debian-12)
ℹ️  Node Runtime
   22 (from 22.19.1)

🐘 PHP Application Dependencies
================================================================================
ℹ️  PHP Constraint
   >=8.1
ℹ️  Application Packages
   1 dependencies managed by Composer

🔍 PHP Version Compatibility
================================================================================
✅ PHP versions compatible
ℹ️    Infrastructure: PHP 8.1
ℹ️    Composer requires: >=8.1 (>= 8.1)
```

**Icons:**
* ✅ **Success** - Compatible/Passed
* ℹ️  **Info** - Informational message
* ⚠️  **Warning** - Non-critical issue (continues validation)
* ❌ **Error** - Critical compatibility issue (fails validation)

### Security Scan Output

```
🔒 Docker Scout Security Scan
================================================================================
Image: moodle-php:latest
Severity: MEDIUM and above
Format: table

Scanning image...

┌─────────────────────┬──────────┬────────┬─────────────────────┐
│ VULNERABILITY       │ SEVERITY │ STATUS │ PACKAGE             │
├─────────────────────┼──────────┼────────┼─────────────────────┤
│ CVE-2024-1234       │ HIGH     │ Open   │ libssl1.1           │
│ CVE-2024-5678       │ MEDIUM   │ Fixed  │ curl                │
└─────────────────────┴──────────┴────────┴─────────────────────┘

Summary:
  2 vulnerabilities found
  1 HIGH
  1 MEDIUM
```

---

## 🚀 Integration with Git Hooks

### Pre-Commit Hook

Create `.git/hooks/pre-commit`:

```bash
#!/bin/bash
# Validate version consistency before commit

echo "🔍 Running pre-commit validation..."

# Run PowerShell validation
powershell.exe -ExecutionPolicy Bypass -File ./scripts/local-validate-version-consistency.ps1 -ExitOnError -Quiet

if [ $? -ne 0 ]; then
    echo "❌ Version validation failed. Commit aborted."
    echo "   Run: .\scripts\local-validate-version-consistency.ps1 -ShowReport"
    exit 1
fi

echo "✅ Pre-commit validation passed"
exit 0
```

Make it executable:
```bash
chmod +x .git/hooks/pre-commit
```

---

## 💡 Tips & Best Practices

### 1. Run Validation Frequently

Don't wait for CI/CD to catch issues:

```powershell
# Add to your workflow
.\scripts\local-validate-version-consistency.ps1

# Good times to validate:
# - Before committing version changes
# - After pulling from remote
# - Before creating pull requests
# - After updating dependencies
```

### 2. Use Reports for Documentation

Generate reports for code reviews:

```powershell
.\scripts\local-validate-version-consistency.ps1 -ShowReport
# Opens detailed markdown report in default viewer
# Share this with your PR
```

### 3. Automate Security Scans

Scan after every build:

```powershell
# In your build script
docker-compose build
foreach ($service in @("php", "nginx", "cron")) {
    .\scripts\local-dev-security-scan.ps1 `
        -ImageName "moodle-$service:latest" `
        -MinSeverity "HIGH"
}
```

### 4. Combine with CI/CD

Local scripts provide **immediate feedback**; CI/CD provides **comprehensive validation**:

| Aspect | Local Scripts | CI/CD Pipeline |
|--------|--------------|----------------|
| **Speed** | Instant | 5-10 minutes |
| **Scope** | Quick validation | Full test suite |
| **Environment** | Windows/Docker Scout | Linux/Trivy |
| **Purpose** | Developer feedback | Deployment gate |

**Workflow:**
1. ✅ Local validation (catch obvious issues)
2. ✅ Commit changes
3. ✅ CI/CD validation (comprehensive testing)
4. ✅ Deploy if both pass

---

## 🐛 Troubleshooting

### "Docker Scout not found"

**Problem:** `docker scout` command not recognized

**Solution:**
```powershell
# Verify Docker Desktop is running
docker version

# Check Scout installation
docker scout version

# Install via Docker Desktop Extensions if missing
# Docker Desktop → Settings → Extensions → Docker Scout
```

### "Execution Policy Restricted"

**Problem:** Scripts won't run due to PowerShell policy

**Solution:**
```powershell
# Option 1: Change policy (recommended)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser

# Option 2: Bypass for single execution
PowerShell -ExecutionPolicy Bypass -File .\scripts\script-name.ps1
```

### "Cannot parse PHP version"

**Problem:** Validation can't extract version from image tag

**Solution:**
```bash
# Ensure example.versions.env uses standard format:
# ✅ Good: PHP_IMAGE=bitnami/php-fpm:8.1.31-debian-12
# ❌ Bad:  PHP_IMAGE=custom-php:latest

# Use explicit version tags, not 'latest'
```

### "Lock file is older than package file"

**Problem:** Dependencies were updated but lock file wasn't regenerated

**Solution:**
```bash
# For Composer
cd config/moodle
composer update

# For NPM
cd config/lighthouse
npm install
```

---

## 📚 Documentation References

### Security

* **[Security Scanning Guide](../.docs/security-scanning.md)**
  Complete guide to multi-tool security scanning strategy

* **[Vulnerability Exception Management](../.docs/vulnerability-exceptions.md)**
  TuxCare integration and exception handling workflow

* **[Security Best Practices](../.docs/security-scanning-best-practices.md)**
  Strategic workflow design and optimization

### Version Management

* **[Centralized Dependency Management](../.docs/centralized-dependency-management.md)**
  Two-tier architecture and philosophy

* **[Version Management Architecture](../.docs/diagrams/version-management-architecture.md)**
  Visual diagrams and workflow sequences

* **[Build & Deployment Flow](../.docs/diagrams/build-deployment-flow.md)**
  Complete CI/CD pipeline visualization

---

## 🤝 Contributing

When adding new scripts to this directory:

1. **Follow PowerShell best practices**
   * Use approved verbs (Get-, Set-, Test-, etc.)
   * Include comprehensive help (`.SYNOPSIS`, `.DESCRIPTION`, `.EXAMPLE`)
   * Support common parameters (`-Verbose`, `-ErrorAction`, etc.)

2. **Provide user feedback**
   * Clear success/error messages
   * Progress indicators for long operations
   * Color-coded output (Green=success, Red=error, Yellow=warning)

3. **Document thoroughly**
   * Update this README with new script details
   * Add usage examples
   * Link to relevant documentation

4. **Test on clean environments**
   * Verify on fresh Windows installs
   * Test both PowerShell 5.1 and 7+
   * Check error handling

---

## 📞 Support

* **Issues:** [GitHub Issues](https://github.com/bcgov/moodle-nginx/issues)
* **Discussions:** [GitHub Discussions](https://github.com/bcgov/moodle-nginx/discussions)
* **Documentation:** [.docs/](../.docs/)

---

*Scripts maintained by BC Gov DevOps Team*
*For production deployments, always rely on CI/CD validation as the final gate*
