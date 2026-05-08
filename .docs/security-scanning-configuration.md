# 🔒 Security Scanning Configuration Guide

## Overview

Flexible, environment-aware security scanning that balances thoroughness with performance. Configuration is managed in `.github/workflows/build.yml` for each branch.

> 💡 **Quick Reference**: For a quick developer guide, see [Security Scanning Quick Reference](./security-scanning.md)

**Related Documentation**:
- [Security Scanning Quick Reference](./security-scanning.md) - Fast troubleshooting guide
- [Security Best Practices](./security-scanning-best-practices.md) - Strategic workflow design
- [Vulnerability Exceptions](./vulnerability-exceptions.md) - Exception management
- [Security Flow Diagrams](./diagrams/security-scanning-flow.md) - Visual architecture

---

## Configuration Variables

Security scan settings are centralized in `example.env` (shared across branches).
Override per-branch in `.github/workflows/build.yml` env section if needed.

```bash
# In example.env
SECURITY_SCAN_ENABLED="YES"                    # Enable/disable security scanning
SECURITY_SCAN_LEVEL="BASIC"                    # Scan thoroughness: MINIMAL, BASIC, FULL, OFF
SECURITY_SCAN_ABORT_DEPLOYMENT_ON="NEVER"      # When to abort: NEVER, CRITICAL, HIGH, MEDIUM
SECURITY_SCAN_CONTAINERS="YES"                 # Include container scanning (expensive)
SECURITY_SCAN_CACHE="YES"                      # Cache scan databases (faster)
```

Additional preflight gate in `checkEnv`:

- Lighthouse dependency audit runs before main scans on `pull_request`, `push`, `schedule`, and `workflow_dispatch`.
- Target branches: `950003-dev`, `950003-test`, `950003-prod`.
- Auto-remediation is attempted with `npm audit fix --package-lock-only --no-fund`.
- Build fails only when high/critical vulnerabilities remain after remediation.

---

## Scan Levels

| Level | What Gets Scanned | Duration | Use Case |
|-------|-------------------|----------|----------|
| **OFF** | Nothing (skip all) | 0 min | Emergency hotfixes |
| **MINIMAL** | Critical CVE advisories only | ~1 min | Fast dev feedback |
| **BASIC** | Composer audit, system packages, Git advisories | ~3 min | Standard dev/test |
| **FULL** | Everything + container image scanning | ~8 min | Production deploys |

---

## Abort Thresholds

Controls when the deployment is aborted based on vulnerability severity:

| Threshold | Deployment Aborted On | Use Case |
|-----------|----------------------|----------|
| **NEVER** | Never (log only) | Dev branches, upstream vuln periods |
| **CRITICAL** | Critical vulnerabilities only | Production (managed risk) |
| **HIGH** | High or Critical | Test environments, pre-prod |
| **MEDIUM** | Medium, High, or Critical | Strict security requirements |

---

## Environment-Specific Settings

### Default (example.env — shared across branches)
```bash
SECURITY_SCAN_LEVEL="BASIC"                    # Fast, standard checks
SECURITY_SCAN_ABORT_DEPLOYMENT_ON="NEVER"      # Never abort deployment
SECURITY_SCAN_CONTAINERS="YES"                 # Include container scanning
```
**Result**: Full scan with reporting only (~6-8 min). Preflight can still fail on unresolved high/critical Lighthouse dependencies.

---

### Override Examples (build.yml per branch)
```yaml
# Test — abort on high+ vulnerabilities
SECURITY_SCAN_LEVEL: "FULL"
SECURITY_SCAN_ABORT_DEPLOYMENT_ON: "HIGH"

# Production — abort on critical only
SECURITY_SCAN_LEVEL: "FULL"
SECURITY_SCAN_ABORT_DEPLOYMENT_ON: "CRITICAL"
```

---

## Summary

✅ **Scan Levels**: Control what gets scanned (MINIMAL/BASIC/FULL)
✅ **Abort Thresholds**: Control when deployments abort (NEVER/CRITICAL/HIGH/MEDIUM)
✅ **Centralized Config**: Settings in `example.env`, override per-branch in `build.yml`
✅ **Performance**: Skip expensive scans in dev, enable in prod

**Quick Reference**:
- Dev: Fast feedback, no blocking (BASIC + WARN)
- Test: Comprehensive validation, block serious issues (FULL + HIGH)
- Prod: Maximum security, block critical only (FULL + CRITICAL)

