# 🔒 Security Scanning

Automated security scanning runs on every build to detect vulnerabilities before deployment.

> 📖 **For detailed configuration and implementation details**, see [Security Scanning Configuration Guide](./security-scanning-configuration.md)

## Quick Reference

| Branch | Scan Level | Blocks Build On | Duration |
|--------|------------|-----------------|----------|
| **950003-dev** | BASIC | Never (warnings only) | ~3 min |
| **950003-test** | FULL | High/Critical issues | ~8 min |
| **950003-prod** | FULL | Critical issues only | ~8 min |

---

## What Gets Scanned

### BASIC Scan (Dev)
- ✅ PHP dependencies (Composer audit)
- ✅ System packages (security updates)
- ✅ Git repositories (security advisories)
- ❌ Container images (skipped for speed)

### FULL Scan (Test/Prod)
- ✅ Everything in BASIC
- ✅ Container image vulnerabilities (Trivy)
- ✅ License compliance checks

---

## When Builds Fail

| Severity | Dev | Test | Prod |
|----------|-----|------|------|
| **Low** | ⚠️ Warn | ⚠️ Warn | ⚠️ Warn |
| **Medium** | ⚠️ Warn | ⚠️ Warn | ⚠️ Warn |
| **High** | ⚠️ Warn | ❌ **FAIL** | ⚠️ Warn |
| **Critical** | ⚠️ Warn | ❌ **FAIL** | ❌ **FAIL** |

---

## Configuration

Settings are in `.github/workflows/build.yml` (per branch):

```yaml
env:
  SECURITY_SCAN_LEVEL: "BASIC"      # OFF, MINIMAL, BASIC, FULL
  SECURITY_SCAN_EXIT_ON: "WARN"     # WARN, CRITICAL, HIGH, MEDIUM, ANY
  SECURITY_SCAN_CONTAINERS: "NO"    # YES, NO
```

---

## If Your Build Fails

### 1. Check Build Logs
Look for `❌ CRITICAL security issues found` in the workflow output.

### 2. Review Findings
Security scan will show:
- Package name and version
- Vulnerability severity (Critical/High)
- CVE ID (e.g., CVE-2024-1234)
- Fix available (yes/no)

### 3. Fix the Issue

**Option A: Update Dependencies**
```bash
# Update specific package
composer update vendor/package-name

# Update all dependencies
composer update
```

**Option B: Document Exception**
If vulnerability can't be fixed immediately:
1. Create issue documenting the risk
2. Get approval from security team
3. Proceed with managed risk (test/prod only block Critical)

---

## Emergency Bypass

**⚠️ Use only for critical production hotfixes**

Temporarily disable scanning in `build.yml`:
```yaml
env:
  SECURITY_SCAN_LEVEL: "OFF"
```

**Remember to re-enable after hotfix!**

---

## Additional Resources

- [Detailed Configuration Guide](./security-scanning-configuration.md)
- [Security Best Practices](./security-scanning-best-practices.md)
- [Vulnerability Exception Management](./vulnerability-exceptions.md)
- [Security Flow Diagrams](./diagrams/security-scanning-flow.md)
- [Dependabot Configuration](../.github/dependabot.yml)

---

**Questions?** Contact DevOps team or check internal wiki.
