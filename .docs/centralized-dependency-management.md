# Centralized Dependency Management & Security

## 📖 Overview

This document outlines our **two-tier version management architecture** that balances centralized control with ecosystem-native dependency management. This hybrid approach maintains infrastructure consistency while preserving the power of Composer and NPM for application dependencies.

---

## 🏗️ Two-Tier Architecture

### Philosophy

**Not all versions should be centralized.** We distinguish between:

| Tier | Purpose | Managed In | Update Frequency |
|------|---------|------------|------------------|
| **Infrastructure** | Runtime environments, base images | `example.versions.env` | Quarterly / Major releases |
| **Application** | Libraries, frameworks, tools | `composer.json`, `package.json` | Monthly / Security patches |

### Why Separation Works

1. **Different Lifecycles**: Infrastructure changes (PHP 8.1 → 8.2) are architectural decisions; library updates (zipstream 3.2 → 3.3) are routine maintenance
2. **Tool Integration**: Composer/NPM handle dependency resolution, peer dependencies, and semantic versioning natively
3. **Ecosystem Compatibility**: Dependabot, security scanners, and IDE tools work without custom wrappers
4. **Team Expertise**: DevOps manages infrastructure; developers manage application dependencies

---

## Tier 1: Infrastructure Versions 🏗️

### Managed in `example.versions.env`

**Scope:** Components that define the *runtime environment*

```bash
# ============================================================================
# INFRASTRUCTURE VERSIONS - Runtime Environments
# ============================================================================

# PHP Runtime (changes require compatibility testing)
PHP_IMAGE=bitnami/php-fpm:8.1.31-debian-12
PHP_VERSION=8.1

# Node.js Runtime (build tools and testing)
NODE_VERSION=22.19.1
NODE_IMAGE=node:22.19.1-alpine

# Web Server
NGINX_IMAGE=nginx:1.25.5
NGINX_VERSION=1.25

# Database
MARIADB_IMAGE=bitnami/mariadb-galera:11.5.2-debian-12
MARIADB_VERSION=11.5

# Cache Layer
REDIS_IMAGE=redis:7.2.6-alpine
REDIS_VERSION=7.2

# Moodle Platform
MOODLE_VERSION=4.5.2
MOODLE_IMAGE=bitnami/moodle:4.5.2-debian-12
```

### Update Process

```bash
# 1. Test new infrastructure version locally
docker build --build-arg PHP_IMAGE=bitnami/php-fpm:8.2.0-debian-12 .

# 2. Update example.versions.env
PHP_IMAGE=bitnami/php-fpm:8.2.0-debian-12
PHP_VERSION=8.2

# 3. Validate application compatibility
./openshift/scripts/validate-version-consistency.sh

# 4. Update application constraints if needed
# In config/moodle/composer.json:
"php": ">=8.2"

# 5. Commit infrastructure and application changes together
git add example.versions.env config/moodle/composer.json
git commit -m "Upgrade PHP infrastructure to 8.2"
```

---

## Tier 2: Application Dependencies 📦

### PHP Dependencies (`composer.json`)

**Scope:** Libraries *installed by* PHP runtime

```json
{
  "require": {
    "php": ">=8.1",
    "maennchen/zipstream-php": "^3.2.0"
  },
  "config": {
    "platform": {
      "php": "8.1.31"
    }
  }
}
```

**Key Features:**
- **Semantic Versioning**: Use `^3.2.0` for automatic compatible updates
- **PHP Constraint**: Documents minimum PHP version (must match Tier 1)
- **Platform Config**: Locks Composer to specific runtime version
- **Dependabot**: Monitors and auto-updates within constraints

### NPM Dependencies (`package.json`)

**Scope:** JavaScript tools *installed by* Node runtime

```json
{
  "dependencies": {
    "lighthouse": "^13.0.1",
    "puppeteer": "^24.15.0"
  },
  "engines": {
    "node": ">=22.0.0"
  }
}
```

**Key Features:**
- **Semantic Versioning**: Automatic minor/patch updates
- **Node Constraint**: Documents minimum Node version (must match Tier 1)
- **Lock File**: `package-lock.json` committed for reproducible builds
- **Dependabot**: Security updates within version ranges

### Update Process

```bash
# PHP dependencies
cd config/moodle
composer update                    # Update within constraints
composer audit                     # Security check
git add composer.json composer.lock
git commit -m "Update PHP dependencies"

# NPM dependencies
cd config/lighthouse
npm update                         # Update within constraints
npm audit                          # Security check
git add package.json package-lock.json
git commit -m "Update NPM dependencies"
```

---

## 🔄 Version Consistency Validation

### Automated Validation Script

`validate-version-consistency.sh` ensures Tier 1 and Tier 2 remain compatible:

```bash
./openshift/scripts/validate-version-consistency.sh
```

### What It Checks

| Check | Purpose | Action on Failure |
|-------|---------|-------------------|
| **PHP Infrastructure vs Composer** | Ensures PHP runtime meets `composer.json` constraint | Update `PHP_IMAGE` in `example.versions.env` |
| **Node Infrastructure vs NPM** | Ensures Node runtime meets `package.json` engines | Update `NODE_VERSION` in `example.versions.env` |
| **Documentation Completeness** | Ensures application versions are noted | Add comment to `example.versions.env` |

### Example Output

```
ℹ️  Infrastructure versions:
ℹ️    PHP: 8.1 (from bitnami/php-fpm:8.1.31-debian-12)
ℹ️    Node: 22 (from 22.19.1)

ℹ️  Composer versions:
ℹ️    PHP constraint: >=8.1

ℹ️  NPM versions:
ℹ️    Node constraint: >=22.0.0
ℹ️    Lighthouse: ^13.0.1

✅ PHP versions compatible:
✅   Infrastructure: PHP 8.1
✅   Composer requires: >=8.1 (>= 8.1)

✅ Node versions compatible:
✅   Infrastructure: Node 22
✅   NPM requires: >=22.0.0 (>= 22)

✅ All version constraints are compatible
```

### CI/CD Integration

Runs automatically in GitHub Actions:

```yaml
- name: 🔄 Version Consistency Check
  run: |
    chmod +x openshift/scripts/validate-version-consistency.sh
    ./openshift/scripts/validate-version-consistency.sh
```

---

## 🎯 Update Workflows

### Scenario 1: Security Patch for Application Dependency

**Example:** Dependabot reports vulnerability in `zipstream-php`

```bash
# 1. Dependabot creates PR updating composer.json
"maennchen/zipstream-php": "^3.2.5"  # Was 3.2.0

# 2. Review and merge (no infrastructure changes needed)
# 3. Validation runs automatically in CI/CD
./openshift/scripts/validate-version-consistency.sh  # ✅ Passes

# 4. Deploy with confidence
```

**No changes to `example.versions.env` needed** - application dependency updates are independent.

### Scenario 2: Major PHP Upgrade

**Example:** Upgrade from PHP 8.1 to PHP 8.3

```bash
# 1. Update infrastructure version
# In example.versions.env:
PHP_IMAGE=bitnami/php-fpm:8.3.0-debian-12
PHP_VERSION=8.3

# 2. Run validation
./openshift/scripts/validate-version-consistency.sh
# ❌ PHP version mismatch:
#   Infrastructure: PHP 8.3
#   Composer requires: >=8.1 (>= 8.1)
#   Action: Upgrade PHP constraint in composer.json

# 3. Update application constraint
# In config/moodle/composer.json:
"php": ">=8.3"

# 4. Test application dependencies compatibility
cd config/moodle
composer update  # Ensure all packages work with PHP 8.3

# 5. Re-validate
./openshift/scripts/validate-version-consistency.sh  # ✅ Passes

# 6. Commit both tiers together
git add example.versions.env config/moodle/composer.json config/moodle/composer.lock
git commit -m "Upgrade infrastructure and application to PHP 8.3"
```

### Scenario 3: Adding New Application Dependency

**Example:** Add Guzzle HTTP client

```bash
# 1. Add to composer.json (standard Composer workflow)
cd config/moodle
composer require guzzlehttp/guzzle:^7.0

# 2. Validation runs automatically
./openshift/scripts/validate-version-consistency.sh  # ✅ Passes

# 3. Optional: Document in example.versions.env
# Add comment for visibility:
# Application dependencies (managed in composer.json):
#   - maennchen/zipstream-php: ^3.2.0
#   - guzzlehttp/guzzle: ^7.0

# 4. Commit
git add config/moodle/composer.json config/moodle/composer.lock
git commit -m "Add Guzzle HTTP client dependency"
```

**No infrastructure impact** - pure application change.

---

## 🛡️ Security Strategy

### Multi-Layer Defense

| Layer | Tool | Scope | Frequency |
|-------|------|-------|-----------|
| **Infrastructure Images** | Trivy | Base images, system packages | Every build |
| **PHP Dependencies** | Composer Audit | Application libraries | Every build |
| **NPM Dependencies** | NPM Audit | JavaScript tools | Every build |
| **GitHub Dependabot** | Security Advisories | composer.json, package.json | Real-time |
| **Version Consistency** | Custom Validation | Tier 1 ↔ Tier 2 compatibility | Every build |

### Dependency Update Security

```bash
# Built into Docker builds
RUN composer audit --format=table && \
    composer validate --strict && \
    npm audit --audit-level=moderate
```

### Supply Chain Protection

1. **Lock Files Committed**: `composer.lock`, `package-lock.json` ensure reproducible builds
2. **Fixed Infrastructure Versions**: Exact versions in `example.versions.env` prevent drift
3. **Automated Validation**: CI/CD fails on version mismatches
4. **Security Scanning**: Multi-tool approach catches vulnerabilities at all layers

---

## 📊 Validation Report

The validation script generates comprehensive reports:

```bash
./openshift/scripts/validate-version-consistency.sh
# Generates: tmp/version-consistency-report.md
```

**Report Contents:**
- Infrastructure version summary
- Application dependency constraints
- Compatibility validation results
- Update workflow documentation
- Recommended actions for detected issues

**GitHub Actions Integration:**
- Automatically added to workflow summary
- Visible in PR checks
- Archived as build artifact

---

## 🔧 Troubleshooting

### Issue: Version Mismatch Detected

**Symptom:**
```
❌ PHP version mismatch:
  Infrastructure: PHP 8.2
  Composer requires: >=8.3 (>= 8.3)
```

**Resolution:**
Either upgrade infrastructure OR downgrade application constraint:
```bash
# Option A: Upgrade infrastructure
# In example.versions.env:
PHP_IMAGE=bitnami/php-fpm:8.3.0-debian-12

# Option B: Relax application constraint (if 8.2 is actually compatible)
# In composer.json:
"php": ">=8.1"  # Was >=8.3
```

### Issue: Dependabot Update Breaks Build

**Symptom:** Dependabot updates `composer.json`, but new version incompatible with PHP 8.1

**Resolution:**
1. Review compatibility in package changelog
2. Either update infrastructure to newer PHP, OR
3. Add version constraint to prevent incompatible updates:
```json
"maennchen/zipstream-php": "^3.2.0 <4.0.0"  # Block PHP 8.2+ requirement
```

### Issue: NPM Audit Failures

**Symptom:** `npm audit` reports vulnerabilities in Lighthouse dependencies

**Resolution:**
```bash
cd config/lighthouse
npm audit fix          # Auto-fix compatible updates
npm audit fix --force  # Force updates (may break compatibility)
npm update lighthouse puppeteer  # Update to latest compatible versions
```

---

## 📚 Best Practices

### ✅ DO

1. **Update infrastructure and application constraints together** when doing major upgrades
2. **Run validation after any version changes** (`validate-version-consistency.sh`)
3. **Use semantic versioning ranges** in Composer/NPM (`^`, `~`)
4. **Document application versions** in `example.versions.env` comments for visibility
5. **Commit lock files** (`composer.lock`, `package-lock.json`) to ensure reproducibility
6. **Review Dependabot PRs promptly** to maintain security posture

### ❌ DON'T

1. **Don't centralize application dependencies** in `example.versions.env` - defeats ecosystem tools
2. **Don't manually edit lock files** - always use `composer update` / `npm install`
3. **Don't skip validation** - catches compatibility issues early
4. **Don't upgrade infrastructure without testing** application dependency compatibility
5. **Don't use exact versions in composer.json** unless security requires it (`3.2.0` vs `^3.2.0`)

---

## 🎓 Understanding the Trade-offs

### Why Not Fully Centralize?

**Tempting:** Put all versions in `example.versions.env` and generate `composer.json`

**Problems:**
- Breaks `composer update` workflow (regenerates file)
- Loses semantic versioning benefits (`^`, `~` ranges)
- Dependabot can't update (doesn't understand env files)
- IDE/tooling integration fails (expects standard files)
- Team must learn custom system instead of standard tools

### Why This Hybrid Works

**Infrastructure Stability + Application Flexibility**

- Infrastructure changes are rare architectural decisions → Centralized control appropriate
- Application updates are frequent routine maintenance → Ecosystem tools optimized for this
- Validation ensures the two tiers stay compatible → Best of both worlds

---

## 📁 File Structure

```
├── example.versions.env                     # Tier 1: Infrastructure versions
├── openshift/scripts/
│   └── validate-version-consistency.sh      # Automated compatibility validation
├── config/moodle/
│   ├── composer.json                        # Tier 2: PHP application dependencies
│   └── composer.lock                        # Committed for reproducibility
├── config/lighthouse/
│   ├── package.json                         # Tier 2: NPM application dependencies
│   └── package-lock.json                    # Committed for reproducibility
└── .github/workflows/
    └── build.yml                            # CI/CD with automated validation
```

---

## 🚀 Summary

**Two-Tier Architecture Benefits:**

| Aspect | Benefit | Result |
|--------|---------|--------|
| **Clarity** | Clear infrastructure vs application separation | Teams know which file to update |
| **Tool Integration** | Standard Composer/NPM workflows work | Dependabot, IDEs, security scanners all functional |
| **Security** | Multi-layer validation | Infrastructure stability + application flexibility |
| **Maintenance** | Automated consistency checks | Catch compatibility issues in CI/CD |
| **Expertise** | DevOps and developers use native tools | No custom learning curve |

**This architecture recognizes that version management is not one-size-fits-all.** Infrastructure requires centralized control; application dependencies benefit from ecosystem-native tools. Validation automation bridges the gap, ensuring compatibility without sacrificing flexibility.


