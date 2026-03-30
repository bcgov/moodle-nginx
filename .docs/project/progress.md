# 📊 Project Progress

High-level overview of CI/CD pipeline maturity, recent milestones, and active work.

---

## Pipeline Maturity

```mermaid
timeline
    title CI/CD Hardening Timeline (950003-dev)
    section Foundation
        Pod Health Monitoring       : Galera auto-heal, service health checks
        Monitoring Deployment       : Continuous pod-health-monitor
        Log Aggregation             : Inline + webhook forwarding
    section Build Optimization
        Lighthouse Front-loading    : NPM + APT deps cached in checkEnv
        Parallel Lighthouse Monitor : Runs alongside builds/deploy
        Maintenance-mode Failsafe  : Auto-enable on critical audit failure
    section Pipeline Hardening
        Utility Script Extraction   : site-monitor, deploy-logs, lighthouse-audit, maintenance-mode
        Trivy Cache Fix             : Eliminate DB collision between jobs
        Deploy Timeout Tuning       : 600s → 2400s for PVC-heavy deploys
        Pipeline Failure Detection  : GitHub API job status early-exit
    section CI Modernization
        Node.js 24 Action Upgrades  : 37 references across 10 workflows
        Lighthouse Output Streaming : Live per-page timing + scores in CI log
        Human-readable Timings      : Minutes/seconds in all monitor output
        Navigation + Score Fixes    : 120s timeout, Math.round scores
```

---

## Recent Commits (950003-dev)

| Commit | Summary |
|--------|---------|
| `b657b16` | fix(lighthouse): tee stdout leak, warn_count bug, nav timeout, score precision |
| `cd5871c` | fix(monitor): human-readable timings, fix HTTP 000000, stream Lighthouse output |
| `8f0919f` | chore(ci): upgrade GitHub Actions to Node.js 24 native versions |
| `c7327ec` | Merge branch — resolve divergence from amended commit |
| `4615719` | fix(build): extract monitoring utilities, fix Trivy cache and deploy timeouts |
| `bec6e64` | perf(build): parallel lighthouse monitor, job log capture, Node.js 24 opt-in |
| `91cd9f6` | fix(build): logging stubs for Lighthouse NPM security scan step |
| `777d164` | perf(build): front-load Lighthouse deps and security scan into checkEnv |
| `37e49b0` | fix(monitor): detailed per-pod issue reporting and post-restart verification |
| `28c448a` | fix(monitor): periodic status reporting, fix silent health checks |
| `012276b` | perf(build): optimize Lighthouse Audit job, add maintenance-mode failsafe |
| `1ff7adf` | refactor(monitor): remove dead files, consolidate health check functions |

---

## Architecture at a Glance

```mermaid
graph LR
    subgraph "GitHub Actions"
        Build["🔨 Build Phase<br/>PHP · Moodle · Web · Cron<br/>Redis Proxy · Helm"]
        Deploy["🚀 Deploy Phase<br/>Template · Migrate · Upgrade<br/>Scale · Right-size"]
        LH["🔭 Lighthouse Monitor<br/>Site monitor · Deploy logs<br/>Performance audit"]
        Notify["📫 Notify<br/>Rocket.Chat"]
    end

    subgraph "OpenShift Silver"
        Web["🌐 Nginx"]
        PHP["🐘 PHP-FPM<br/>(Moodle)"]
        DB["🗄️ MariaDB<br/>Galera 3-node"]
        Redis["💾 Redis<br/>Sentinel 3-node"]
        Cron["⏰ Cron"]
        Monitor["🔍 Pod Health<br/>Monitor"]
    end

    Build --> Deploy --> Notify
    Build --> LH --> Notify
    Deploy --> Web & PHP & DB & Redis & Cron
    Monitor --> PHP & Redis & DB

    style Build fill:#e8f5e9
    style Deploy fill:#e1f5fe
    style LH fill:#e8eaf6
    style Monitor fill:#fff3e0
```

---

## CI/CD Pipeline Components

| Component | Status | Notes |
|-----------|--------|-------|
| **Security scanning** | ✅ Active | Trivy + Composer audit + NPM audit; environment-tiered |
| **Lighthouse audit** | ✅ Active | 5 pages, per-page timing, live streaming, maintenance failsafe |
| **Site monitor** | ✅ Active | State machine with human-readable timings, pipeline failure early-exit |
| **Deploy log capture** | ✅ Active | migrate-build-files + moodle-upgrade job logs |
| **Node.js 24 actions** | ✅ Complete | 37 references upgraded; 3 third-party actions use env var fallback |
| **Pod health monitoring** | ✅ Active | Galera auto-heal, service health checks, webhook notifications |
| **Docker layer caching** | ✅ Active | Artifactory registry, buildx cache |
| **Trivy DB caching** | ✅ Fixed | Branch-prefixed keys, continue-on-error for save collisions |

---

## Known Issues / Technical Debt

| Issue | Priority | Notes |
|-------|----------|-------|
| `falti/dotenv-action@v1` no node24 release | Medium | May silently fail under Node 24; env var fallback active |
| `WyriHaximus/github-action-helm3@v3` no node24 | Low | Cosmetic deprecation warning only |
| `muinmomin/webhook-action@v1.0.0` no node24 | Low | Cosmetic deprecation warning only |
| Lighthouse page load ~70s each | Low | Inherent to Lighthouse profiling; cold cache adds ~10-20s first page |
| Documentation gaps (README, scripts/utils) | Low | In progress |

---

## Related Documentation

- **[Build & Deployment Flow](./../diagrams/build-deployment-flow.md)** — Complete pipeline architecture with Mermaid diagrams
- **[Security Scanning](./../security-scanning.md)** — Configuration and environment-tier strategy
- **[Logging Levels](./../logging-levels.md)** — Three-tier logging system (INFO/DEBUG/TRACE)
- **[Galera Monitoring](./../galera-monitoring-solution.md)** — Pod health monitor architecture
- **[Centralized Dependencies](./../centralized-dependency-management.md)** — Two-tier version management
