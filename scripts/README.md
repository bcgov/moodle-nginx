# 🛠️ Local Development Scripts

This directory contains PowerShell scripts to assist with **local development tasks** on Windows environments. These scripts provide immediate feedback and validation before committing changes or running CI/CD pipelines.

---

## 📋 Available Scripts

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
