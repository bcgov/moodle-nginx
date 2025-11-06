# Centralized Dependency Management & Security

## Overview

This document outlines our streamlined approach to managing all dependencies (Docker images, PHP packages, Helm charts, etc.) from a single source of truth while maintaining robust security scanning and supply chain attack prevention.

## Architecture

### Single Source of Truth ✅

All dependency versions are centrally managed in `example.versions.env`:

```bash
# Application PHP Dependencies (security-controlled versions)
ZIPSTREAM_PHP_VERSION=2.4.1  # Fixed version for security validation

# Base images for containers (managed by Dependabot)
PHP_IMAGE=php:8.1-fpm
CRON_IMAGE=php:8.1-cli
DB_IMAGE=mariadb:10
# ... etc
```

### Automated Generation Flow 🔄

```
example.versions.env → populate-dependency-manifests.sh → {
  config/moodle/composer.json           (PHP dependencies)
  openshift/dependencies/images.yml     (Docker images)
  openshift/dependencies/Chart.yaml     (Helm charts)
  .github/security-tools.json           (Security tools)
  config/moodle/git-dependencies.json   (Git repositories)
  .env.generated                        (Local development)
}
```

### Benefits of Consolidated Approach

1. **Single File Management**: One `composer.json` for both production and security scanning
2. **Developer Clarity**: No confusion about which file to use or modify
3. **Reduced Maintenance**: Fewer files to track and maintain
4. **Consistent Security**: Same file used for runtime and Dependabot scanning

## Security Strategy

### 1. Supply Chain Attack Prevention 🔒

#### Fixed Versions
- Use exact versions (e.g., `2.4.1`) instead of ranges (e.g., `^2.1`)
- Prevents automatic updates that could introduce malicious code
- Allows controlled testing of updates

#### Generated File Protection
```bash
# composer.json includes generation metadata
{
  "extra": {
    "generated_at": "2025-10-29T12:00:00Z",
    "source_file": "example.versions.env",
    "generator": "populate-dependency-manifests.sh"
  }
}
```

### 2. Multi-Layer Security Scanning 🛡️

#### Docker Build Security
```dockerfile
# In Moodle.Dockerfile
RUN composer update --no-dev --optimize-autoloader --no-scripts && \
    composer audit --format=table && \
    composer validate --strict
```

#### Automated Security Tools
- **Composer Audit**: Built-in vulnerability scanning
- **Dependabot**: Automated security advisory monitoring on the single composer.json
- **Custom Security Validation**: `./openshift/scripts/validate-php-security.sh`

### 3. Version Drift Detection 📊

The security validation script automatically detects when manually edited files drift from centralized management:

```bash
./openshift/scripts/validate-php-security.sh
```

Checks:
- ✅ Versions match `example.versions.env`
- ✅ Files contain generation metadata
- ✅ No security vulnerabilities
- ✅ License compliance

## Usage Workflows

### 1. Adding New Dependencies

1. **Add to centralized versions:**
   ```bash
   # In example.versions.env
   NEW_PACKAGE_VERSION=1.2.3
   ```

2. **Update the generation script:**
   ```bash
   # Edit populate-dependency-manifests.sh to include new package
   "vendor/new-package": "${NEW_PACKAGE_VERSION}"
   ```

3. **Generate updated files:**
   ```bash
   ./openshift/scripts/populate-dependency-manifests.sh
   ```

4. **Validate security:**
   ```bash
   ./openshift/scripts/validate-php-security.sh
   ```

### 2. Security Update Process

1. **Dependabot creates PR** with security advisory on composer.json
2. **Review security impact** and test changes
3. **Update version in `example.versions.env`**
4. **Regenerate composer.json** to maintain centralized control
5. **Deploy with full testing**

### 3. Regular Maintenance

#### Daily (Automated)
- Dependabot scans composer.json for vulnerabilities
- CI/CD security validation on all builds

#### Weekly
- Review Dependabot alerts
- Run manual security validation
- Check for outdated dependencies

#### Monthly
- Update to latest secure versions in example.versions.env
- Regenerate all dependency manifests
- Review license compliance

## Integration with Existing Tools

### GitHub Security Features ✅
- **Dependabot**: Scans the single `config/moodle/composer.json` file
- **Security Advisories**: GitHub's vulnerability database integration
- **Code Scanning**: Automated security analysis in PRs

### CI/CD Pipeline Integration ✅
```yaml
# In .github/workflows/build.yml
- name: 🔄 Auto-populate dependency manifests
  run: |
    chmod +x openshift/scripts/populate-dependency-manifests.sh
    ./openshift/scripts/populate-dependency-manifests.sh

- name: 🔒 PHP Security Validation
  run: |
    chmod +x openshift/scripts/validate-php-security.sh
    ./openshift/scripts/validate-php-security.sh
```

### Local Development ✅
```bash
# Generate .env.generated for docker-compose
./openshift/scripts/populate-dependency-manifests.sh

# Use generated environment file
docker-compose --env-file .env.generated up
```

## File Structure

```
├── example.versions.env                    # Single source of truth for ALL versions
├── openshift/scripts/
│   ├── populate-dependency-manifests.sh    # Generates all dependency files
│   └── validate-php-security.sh           # Security validation and drift detection
├── config/moodle/
│   └── composer.json                      # Generated PHP deps (production + Dependabot)
├── openshift/dependencies/
│   ├── images.yml                         # Generated Docker images (Dependabot)
│   └── Chart.yaml                         # Generated Helm charts (Dependabot)
└── .github/
    └── security-tools.json                # Generated security tools versions
```

## Security Best Practices

### 1. Never Edit Generated Files Manually ⚠️
- Always update `example.versions.env` first
- Run `populate-dependency-manifests.sh` to regenerate
- Generated files include metadata to detect manual edits

### 2. Regular Security Validation ✅
```bash
# Before committing changes
./openshift/scripts/validate-php-security.sh

# Check for version drift
grep -r "generated_at" config/moodle/composer.json
```

### 3. Emergency Security Response 🚨
1. **Critical Vulnerability Found:**
   - Update version in `example.versions.env`
   - Regenerate composer.json immediately
   - Deploy emergency patch
   - Full regression testing

## Migration from Multiple Files

If you previously had separate files like `composer.generated.json`, they can be safely removed after confirming the new system works:

```bash
# After successful testing, remove old generated file
rm config/moodle/composer.generated.json

# Ensure gitignore includes generated files that should not be committed
echo "config/moodle/composer.lock" >> .gitignore
```
