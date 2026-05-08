# Developer Documentation

PowerShell tools for local development, in-cluster automation, and operational workflows.

---

## 📋 Quick Reference

### Right-Sizing & Resource Management
- **[right-sizing-galera-integration.md](right-sizing-galera-integration.md)** - Unified CSV-based resource management + database configuration

### Pod Health Monitoring
- **[pod-health-monitor-utilities.md](pod-health-monitor-utilities.md)** - In-cluster monitoring, auto-healing, and utility management
- **[manual-mode-override.md](manual-mode-override.md)** - Disable automated actions during manual interventions

### Split-Brain Resolution
- **[split-brain/](split-brain/)** - Complete documentation for Galera split-brain prevention, diagnosis, and recovery

---

## 🔧 PowerShell Tools (Local Development)

Located in `./scripts/`

### Resource Management
```powershell
# Upload CSV + my.cnf, trigger in-cluster right-sizing
.\scripts\update-right-sizing.ps1 -Namespace 950003-dev

# Only adjust specific deployment (safe for database changes)
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod -Deployments mariadb-galera

# Upload custom my.cnf variation
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod -MyCNF config\mariadb\my-test-PT35S.cnf

# Preview changes without applying
.\scripts\update-right-sizing.ps1 -Namespace 950003-test -DryRun
```

### Galera Cluster Management
```powershell
# Upload utility scripts to pod-health-monitor
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action UploadUtilities

# Run diagnostics
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Diagnose

# Verify cluster health
.\scripts\manage-galera-utilities.ps1 -Namespace 950003-prod -Action Verify
```

### Bootstrap & Recovery
```powershell
# Bootstrap Galera cluster from scratch
.\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-dev

# Check timeout configuration
.\scripts\check-galera-timeout-config.ps1 -Namespace 950003-prod

# Measure network latency
.\scripts\measure-galera-network-latency.ps1 -Namespace 950003-prod
```

---

## 🐚 In-Cluster Scripts (pod-health-monitor)

Located in `/scripts/` inside pod-health-monitor container

### Continuous Monitoring
```bash
# Primary health check script (runs continuously)
bash /scripts/check-pod-logs.sh

# Monitor specific pods
bash /scripts/monitor-pods.sh
```

### Right-Sizing Execution
```bash
# Apply CSV-based resource configuration
export DEPLOY_NAMESPACE=950003-dev
export CSV_SOURCE=configmap
bash /scripts/right-sizing.sh
```

### Galera Utilities
```bash
# Inspect cluster health
bash /scripts/galera-inspect.sh

# Auto-detect and apply timeout profile
bash /scripts/utils/apply-galera-timeouts.sh --auto-detect

# Apply specific profile
bash /scripts/utils/apply-galera-timeouts.sh --profile production --namespace 950003-prod
```

---

## 🗂️ Configuration Files

### Environment-Specific Database Configs
- `config/mariadb/950003-dev.cnf` - Development (PT20S timeouts, 2 replicas)
- `config/mariadb/950003-test.cnf` - Test (PT25S timeouts, 3 replicas)
- `config/mariadb/950003-prod.cnf` - Production (PT30S timeouts, 5 replicas)

### Right-Sizing CSVs
- `openshift/950003-dev-sizing.csv` - Development resource allocation
- `openshift/950003-test-sizing.csv` - Test resource allocation
- `openshift/950003-prod-sizing.csv` - Production resource allocation

---

## 📚 Detailed Documentation

### Split-Brain Resolution
- **[Split-Brain Documentation](split-brain/)** - Complete guide to prevention, diagnosis, and recovery

### Architecture
- **[Galera Monitoring Solution](../galera-monitoring-solution.md)** - Pod health monitor architecture
- **[Build & Deployment Flow](../diagrams/build-deployment-flow.md)** - Complete CI/CD pipeline

### Operations
- **[Manual Galera Troubleshooting](../manual-galera-troubleshooting.md)** - Step-by-step recovery procedures
- **[Logging Levels](../logging-levels.md)** - Three-tier logging system (INFO/DEBUG/TRACE)

---

## 🔍 Universal _utils.sh Loader

All bash scripts use a universal loader pattern that works in all environments:

```bash
# Universal _utils.sh loader - works in all environments
# Priority: same-dir > /scripts > /usr/local/bin > ./openshift/scripts
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1
```

**Environments supported:**
- GitHub Actions runner (same directory)
- pod-health-monitor (`/scripts/`)
- Docker Compose (`/usr/local/bin/`)
- OpenShift Jobs (`/usr/local/bin/`)
- Local development (`./openshift/scripts/`)

---

## 🚀 Getting Started

1. **Review [right-sizing-galera-integration.md](right-sizing-galera-integration.md)** for unified resource + database management
2. **Read [split-brain/](split-brain/)** if working on Galera cluster issues
3. **Check [pod-health-monitor-utilities.md](pod-health-monitor-utilities.md)** for monitoring operations
4. **Reference script help** with `-?` or `-Help` parameter for PowerShell tools

---

## 🔗 Related

- [Project Progress](../project/progress.md) - High-level milestones and timeline
- [Security Scanning](../security-scanning.md) - Trivy, Composer, NPM audit configuration
- [Centralized Dependencies](../centralized-dependency-management.md) - Two-tier version management
