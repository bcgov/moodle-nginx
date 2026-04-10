# OpenShift Deployment Scripts

Comprehensive collection of scripts for deploying and managing the Moodle application on OpenShift.

## 📋 Quick Reference

### Monitoring & Health

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [`check-pod-logs.sh`](./check-pod-logs.sh) | Pod health monitoring with Galera auto-healing | [Architecture](../../.docs/galera-monitoring-solution.md) |
| [`monitor-pods.sh`](./monitor-pods.sh) | Continuous monitoring wrapper | See inline header |
| [`log-aggregator.sh`](./log-aggregator.sh) | Event aggregation and forwarding | See inline header |
| [`deploy-health-monitor.sh`](./deploy-health-monitor.sh) | Deploy monitoring infrastructure | See inline header |

### Core Deployment

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [`deploy-template.sh`](./deploy-template.sh) | Main deployment orchestration | See inline header |
| [`deploy-mariadb-galera.sh`](./deploy-mariadb-galera.sh) | MariaDB Galera cluster deployment with PVC expansion | [Architecture](../../.docs/galera-monitoring-solution.md), [Troubleshooting](../../.docs/manual-galera-troubleshooting.md) |
| [`deploy-redis-sentinel.sh`](./deploy-redis-sentinel.sh) | Redis Sentinel cluster deployment | See inline header |
| [`right-sizing.sh`](./right-sizing.sh) | Resource allocation and PVC expansion management | See inline header |

### Moodle Operations

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [`moodle-upgrade.sh`](./moodle-upgrade.sh) | Database upgrade orchestration | See inline header |
| [`enable-maintenance.sh`](./enable-maintenance.sh) | Enable maintenance mode | See inline header |
| [`migrate-courses-between-namespaces.sh`](./migrate-courses-between-namespaces.sh) | Cross-namespace course migration | See inline header |
| [`migrate-build-files.sh`](./migrate-build-files.sh) | Safe file migration with version checking | See inline header |
| [`deploy-maintenance-message.sh`](./deploy-maintenance-message.sh) | Deploy standalone maintenance page | See inline header |

### Database & Backups

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [`deploy-database-backups.sh`](./deploy-database-backups.sh) | Automated backup deployment (Helm) | See inline header |
| [`mariadb-prestop.sh`](./mariadb-prestop.sh) | Graceful Galera shutdown hook | [Architecture](../../.docs/galera-monitoring-solution.md) |

### Build & CI/CD

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [`build-docker-image.sh`](./build-docker-image.sh) | Trigger OpenShift image builds | See inline header |
| [`populate-dependency-manifests.sh`](./populate-dependency-manifests.sh) | Sync dependency versions | See inline header |

### Security & Validation

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [`comprehensive-security-scan.sh`](./comprehensive-security-scan.sh) | Multi-level security scanning | [CI/CD](../../.github/workflows/build.yml) |
| [`validate-php-security.sh`](./validate-php-security.sh) | PHP dependency CVE scanning | See inline header |
| [`validate-php-compatibility.sh`](./validate-php-compatibility.sh) | PHP version compatibility checks | See inline header |
| [`validate-version-consistency.sh`](./validate-version-consistency.sh) | Infrastructure/app version validation | See inline header |

### Utilities & Helpers

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [`_utils.sh`](./_utils.sh) | Modular utility loader | [Modules](./utils/) |
| [`helm-image-resolver.sh`](./helm-image-resolver.sh) | Image registry resolution (Artifactory) | See inline header |
| [`ensure-artifactory-access.sh`](./ensure-artifactory-access.sh) | Configure imagePullSecrets | See inline header |

### CI/CD Utility Modules (`utils/`)

Extracted, reusable shell modules sourced by GitHub Actions workflow steps. Each module is self-contained with its own logging, error handling, and `GITHUB_OUTPUT` integration.

| Module | Purpose | Used By |
|--------|---------|---------|
| [`openshift.sh`](./utils/openshift.sh) | Core OpenShift operations, logging functions | All scripts |
| [`site-monitor.sh`](./utils/site-monitor.sh) | Deployment state tracker (BASELINE → DEPLOYING → READY), pipeline failure early-exit | [build.yml](../../.github/workflows/build.yml) Lighthouse Monitor |
| [`lighthouse-audit.sh`](./utils/lighthouse-audit.sh) | Lighthouse CI wrapper — environment verification, live output streaming | [build.yml](../../.github/workflows/build.yml) Lighthouse Monitor |
| [`lighthouse.sh`](./utils/lighthouse.sh) | Lighthouse core functions — audit execution, setup, cache management | `lighthouse-audit.sh` |
| [`deploy-logs.sh`](./utils/deploy-logs.sh) | Capture migrate-build-files and moodle-upgrade job logs via `oc logs` | [build.yml](../../.github/workflows/build.yml) Lighthouse Monitor |
| [`maintenance-mode.sh`](./utils/maintenance-mode.sh) | Emergency maintenance mode on Lighthouse audit failure | [build.yml](../../.github/workflows/build.yml) Lighthouse Monitor |
| [`npm.sh`](./utils/npm.sh) | Secure npm install, audit scanning, lockfile validation | `lighthouse.sh`, checkEnv |
| [`docker-security.sh`](./utils/docker-security.sh) | Trivy base image scanning, SBOM generation | checkEnv security scan |
| [`security.sh`](./utils/security.sh) | Security scan orchestration and result caching | `comprehensive-security-scan.sh` |
| [`docker.sh`](./utils/docker.sh) | Docker image build and push helpers | Build workflows |
| [`database.sh`](./utils/database.sh) | Galera/MariaDB operations and health checks | Deployment scripts |
| [`redis.sh`](./utils/redis.sh) | Redis Sentinel operations | Deployment scripts |
| [`moodle.sh`](./utils/moodle.sh) | Moodle-specific operations (cache clear, maintenance) | Deployment scripts |
| [`github-actions.sh`](./utils/github-actions.sh) | GitHub Actions helper functions | CI workflows |
| [`version-management.sh`](./utils/version-management.sh) | Version consistency validation helpers | `validate-version-consistency.sh` |

## 🏗️ Architecture Overview

### Monitoring System

```
┌─────────────────────────────────────────┐
│   Continuous Monitoring Deployment      │
│   (pod-health-monitor.yml)              │
└─────────────────┬───────────────────────┘
                  │
                  ▼
        ┌─────────────────────┐
        │  monitor-pods.sh    │
        │  (wrapper loop)     │
        └──────────┬──────────┘
                   │
                   ▼
        ┌─────────────────────┐
        │ check-pod-logs.sh   │
        │ (core logic)        │
        └──────────┬──────────┘
                   │
      ┌────────────┼────────────┐
      ▼            ▼            ▼
   PHP Pods   Redis Proxy   Galera
                             (auto-heal)
```

### Log Aggregation

**Inline Mode** (default):
```
check-pod-logs.sh → stdout → log-aggregator.sh pipe → webhooks
```

## 🚀 Quick Start

### Deploy Monitoring

```bash
# Deploy continuous monitoring (recommended)
export DEPLOYMENT_TYPE=continuous
./openshift/scripts/deploy-health-monitor.sh

# Or deploy CronJob monitoring (fallback)
export DEPLOYMENT_TYPE=cronjob
./openshift/scripts/deploy-health-monitor.sh
```

### Check Monitoring Status

```bash
# View continuous monitor logs
oc logs -f deployment/pod-health-monitor

# Check recent events
oc get events --field-selector component=galera-monitor

# View CronJob history (if using CronJob mode)
oc get jobs -l job-name=check-pod-logs
```

## 📚 Documentation Structure

### Inline Documentation
All scripts include comprehensive headers with:
- Purpose and overview
- Quick configuration options
- Usage examples
- Links to related documentation

### External Documentation
- **Build & Deployment Flow**: [`.docs/diagrams/build-deployment-flow.md`](../../.docs/diagrams/build-deployment-flow.md)
- **Logging Levels**: [`.docs/logging-levels.md`](../../.docs/logging-levels.md)
- **Architecture**: [`.docs/galera-monitoring-solution.md`](../../.docs/galera-monitoring-solution.md)
- **Manual Troubleshooting**: [`.docs/manual-galera-troubleshooting.md`](../../.docs/manual-galera-troubleshooting.md)
- **Main README**: [Repository root](../../README.md)

### Template Documentation
OpenShift templates include parameter descriptions:
- [`pod-health-monitor.yml`](../pod-health-monitor.yml)
- [`check-pod-logs.yml`](../check-pod-logs.yml)

## 🔧 Configuration

### Environment Variables

Common configuration across deployment scripts:

| Variable | Purpose | Default |
|----------|---------|---------|
| `DEPLOY_NAMESPACE` | Target OpenShift namespace | (required) |
| `OPENSHIFT_SERVER` | OpenShift API server URL | (required) |
| `OPENSHIFT_SA_TOKEN_NAME` | Service account secret | (required) |
| `ROCKETCHAT_WEBHOOK_URL` | RocketChat webhook | (optional) |
| `USE_LOG_AGGREGATOR` | Enable inline log aggregation | `true` |
| `MONITORING_INTERVAL` | Health check interval (seconds) | `60` |
| `GALERA_CHECK_INTERVAL` | Galera check interval (seconds) | `300` |
| `ERROR_THRESHOLD` | Consecutive errors before restart | `3` |

### Webhook Notifications

Configure webhooks for critical event notifications:

```bash
# RocketChat
export ROCKETCHAT_WEBHOOK_URL="https://chat.example.com/hooks/..."

# Slack (if using log-aggregator with separate deployment)
export SLACK_WEBHOOK="https://hooks.slack.com/services/..."

# Syslog (optional)
export SYSLOG_SERVER="syslog.example.com"
```

## 🛠️ Development

### Modular Utilities

The `_utils.sh` file sources modular utilities from the `utils/` directory:

```
utils/
├── openshift.sh           - Core OpenShift operations + logging (log_info, log_debug, etc.)
├── site-monitor.sh        - Deployment state tracker with human-readable timings
├── lighthouse-audit.sh    - Lighthouse CI wrapper with live output streaming
├── lighthouse.sh          - Lighthouse core: audit, setup, cache management
├── deploy-logs.sh         - Post-deploy job log capture (migrate-build-files, moodle-upgrade)
├── maintenance-mode.sh    - Emergency maintenance on audit failure
├── npm.sh                 - Secure npm install + audit scanning
├── docker-security.sh     - Trivy base image scanning + SBOM
├── security.sh            - Security scan orchestration + caching
├── docker.sh              - Docker image build/push helpers
├── github-actions.sh      - GitHub Actions helper functions
├── version-management.sh  - Version consistency validation
├── database.sh            - Galera/MariaDB operations
├── redis.sh               - Redis Sentinel operations
└── moodle.sh              - Moodle-specific operations
```

Each utility module is self-contained and well-documented. See individual files for details.

### Adding New Scripts

When creating new deployment scripts:

1. **Use the header template** from existing scripts
2. **Link to relevant documentation** using relative paths
3. **Keep inline docs focused** on configuration and quick start
4. **Use modular utilities** from `_utils.sh` where possible
5. **Update this README** with the new script entry

### Documentation Guidelines

**DO:**
- ✅ Use relative paths (`../../.docs/...`)
- ✅ Link for architecture/design decisions
- ✅ Keep critical config inline
- ✅ Use section headers for navigation
- ✅ Update links when moving files

**DON'T:**
- ❌ Link to external websites
- ❌ Duplicate entire docs in comments
- ❌ Link for simple code explanations
- ❌ Use absolute GitHub URLs

## 🔍 Troubleshooting

### Monitoring Not Working

1. Check ConfigMaps exist:
   ```bash
   oc get configmap check-pod-logs-script
   oc get configmap pod-health-monitor-script
   oc get configmap log-aggregator-script
   ```

2. Check service account permissions:
   ```bash
   oc describe serviceaccount <SA_NAME>
   oc auth can-i delete pods --as=system:serviceaccount:<namespace>:<SA_NAME>
   ```

3. Check webhook configuration:
   ```bash
   oc get secret notification-webhooks -o yaml
   ```

### Galera Not Auto-Healing

See comprehensive troubleshooting guide:
- [Manual Galera Troubleshooting](../../.docs/manual-galera-troubleshooting.md)
- [Galera Monitoring Solution](../../.docs/galera-monitoring-solution.md)

### Log Aggregation Not Forwarding

1. Check aggregator is enabled:
   ```bash
   oc logs deployment/pod-health-monitor | grep "log aggregation"
   ```

2. Test webhook connectivity:
   ```bash
   curl -X POST "$ROCKETCHAT_WEBHOOK_URL" \
     -H 'Content-Type: application/json' \
     -d '{"text": "Test from Moodle monitoring"}'
   ```

3. Check OpenShift events:
   ```bash
   oc get events | grep galera-monitor
   ```

## 📖 Additional Resources

- **GitHub Actions**: [`.github/workflows/`](../../.github/workflows/)
- **OpenShift Templates**: [`../`](../)
- **Configuration Files**: [`../../config/`](../../config/)
- **Main Documentation**: [`../../.docs/`](../../.docs/)

## 🤝 Contributing

When modifying deployment scripts:

1. Test in dev environment first
2. Update inline documentation headers
3. Update this README if adding new scripts
4. Ensure relative documentation links work
5. Follow the established documentation patterns

---

**Last Updated**: November 2025
**Maintainer**: BCGov PSA LMS Team
