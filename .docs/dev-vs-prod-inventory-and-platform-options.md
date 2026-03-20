# Dev vs Prod Change Inventory and Platform Options

Date: 2026-03-19
Scope: Differences between `origin/950003-dev` and `origin/950003-prod`
Audience: Client and project owner (non-technical decision support)

## Executive Summary

There is a substantial gap between dev and prod.

- Commits in dev not in prod: 213
- Files changed: 92
- Added files: 44
- Modified files: 46
- Deleted files: 2

This is not a single feature gap. It is a combined operations, security, and deployment modernization package.

The immediate business risk is not only "missing features". The larger risk is operational instability and delayed recovery because prod and dev do not behave the same way.

## High-Level Inventory (By Area)

- `openshift/`: 45 files
- `.github/`: 13 files
- `config/`: 11 files
- `.docs/`: 11 files
- `scripts/`: 3 files
- Other root files (`Moodle.Dockerfile`, `example.versions.env`, compose files, etc.): 9 files

## What Changed (Client-Friendly Themes)

### 1) Deployment Reliability and Safety

What it means:
- Better guardrails to reduce accidental bad deploys
- Better logging and error visibility
- Better health checks and recovery behavior

Business value:
- Lower chance of failed releases
- Faster triage when issues occur
- Less manual intervention during incidents

### 2) Security and Compliance Automation

What it means:
- Automated vulnerability scanning was expanded
- Dependency/version checks were added
- Security reporting and artifact capture were improved

Business value:
- Earlier detection of vulnerabilities
- Better auditability for approvals and compliance
- Less dependence on manual security reviews

Current workflow behavior snapshot:
- A fail-fast Lighthouse dependency preflight gate runs in `checkEnv` for `dev`, `test`, and `prod` on PR/push/schedule/manual runs.
- The gate attempts automatic lockfile-only remediation, then re-audits before deciding pass/fail.
- The deployment pipeline proceeds only when high/critical Lighthouse dependency issues are resolved or remediated.
- This reduces late-stage failures and prevents deploying with known vulnerable test-tool dependency states.
- Deploy concurrency is guarded with cancel-in-progress to prevent overlapping release races on the same ref.
- Health-check and cluster monitoring controls are part of the deployment path to improve resilience during rollout.

### 3) Dependency and Version Governance

What it means:
- Centralized dependency/version management became a first-class workflow
- Build manifests and validation were added
- More consistency between environments

Business value:
- Fewer surprises during release
- Better predictability of upgrade impact
- Reduced configuration drift

### 4) Data Platform and Cache Operations

What it means:
- MariaDB Galera and Redis/Sentinel deployment scripts were significantly revised
- Artifactory and image pull behavior were standardized
- Redis proxy and sentinel config were adjusted

Business value:
- Better repeatability of infra deployment
- Better control of image sources and pull secrets
- Lower risk of hidden environment-specific failures

## Bitnami Legacy Images: Practical Risk View

Current concern:
- `bitnamilegacy/*` images for MariaDB Galera, Redis, and Redis Sentinel are used in dev.

Non-technical risk statement:
- Internal-only exposure reduces internet attack risk, but does not remove risk.
- Unmaintained base images increase risk over time from:
  - Supply-chain vulnerabilities
  - Compliance findings
  - Delayed patch response
  - Higher incident impact if internal lateral movement occurs

Recommended interpretation:
- This is a medium-term risk that grows monthly.
- It is less likely to cause immediate outage than a bad deployment, but it is more likely to create security/compliance debt.

## Platform Strategy Options

### Option A: Stabilize First, Then Replace Legacy Images (Recommended)

Description:
- First close the dev/prod reliability gap in controlled waves.
- Then execute a focused image replacement program for MariaDB/Redis stack.

Benefits:
- Lowest delivery risk
- Preserves current application behavior
- Faster path to predictable releases

Risks:
- Legacy image exposure remains during transition period

Timeline estimate:
- 2 to 4 weeks for controlled parity/release hardening
- 2 to 6 additional weeks for image replacement and soak testing

### Option B: Replace Legacy Images Immediately, Keep Current Architecture

Description:
- Keep MariaDB Galera + Redis Sentinel + proxy architecture, but swap image sources/versions.

Benefits:
- Faster reduction of image lifecycle/security debt
- Smaller application-level compatibility risk than database/cache platform migrations

Risks:
- Still requires careful compatibility validation for startup scripts, probes, and chart behavior
- Can introduce deployment instability if rushed

Timeline estimate:
- 3 to 6 weeks depending on test depth and environment parity

### Option C: Migrate MariaDB Galera -> PostgreSQL and Redis/Sentinel -> Valkey

Description:
- Full platform move for database and caching technologies.

Benefits:
- Long-term modernization opportunity
- Potentially cleaner future architecture

Risks:
- Highest migration risk and longest path
- Requires data migration + performance regression testing + rollback strategy
- Moodle compatibility and operational runbooks must be revalidated end-to-end
- Existing Redis proxy assumptions likely need redesign or replacement work

Timeline estimate:
- 3 to 6 months (realistic program-level effort)

## Compatibility Guidance (Moodle-Specific)

### MariaDB Galera -> PostgreSQL

- Moodle supports PostgreSQL, but this is not an in-place image swap.
- It is a data migration project with validation, fallback, and performance tuning.
- Expect dual-run validation and staged cutover planning.

### Redis/Sentinel -> Valkey

- Valkey is protocol-compatible with Redis for many use cases.
- However, your current design includes Redis Sentinel and a custom proxy layer.
- Compatibility is likely at protocol level, but failover/proxy behavior and operational tooling must be revalidated.
- Treat as an architecture migration, not a simple package upgrade.

## Suggested Decision Path for Client Review

1. Approve Option A as primary path (stability and parity first).
2. Start Option B design in parallel (image replacement without platform migration).
3. Treat Option C as a separate modernization initiative with formal discovery phase.

## Suggested Milestones

1. Inventory sign-off and risk acceptance (this document)
2. Dev -> test promotion with explicit go/no-go checklist
3. Test soak period with production-like load and incident simulation
4. Prod promotion for stability package
5. Legacy image replacement wave (MariaDB/Redis stack)
6. Optional discovery charter for PostgreSQL/Valkey migration

## Appendix: Notable Infra and Cache/DB Delta Signals

Examples from dev not in prod include:

- `example.versions.env`
  - Centralized image/dependency strategy introduced
  - Bitnami legacy image pins for MariaDB/Redis/Sentinel present

- `openshift/scripts/deploy-mariadb-galera.sh`
  - Major deployment flow hardening and image resolver integration

- `openshift/scripts/deploy-redis-sentinel.sh`
  - Major image/config handling changes and chart-driven behavior updates

- `openshift/redis-proxy.yml`
  - Pull secret templating and deployment parameterization improvements

- `config/redis/sentinel_tunnel.remote.config.json`
  - Sentinel target list reduced and normalized

- `.github/workflows/build.yml` and related workflows
  - Significant preflight/security/guardrail expansion
  - Branch-aware fail-fast dependency preflight with remediation and re-validation

