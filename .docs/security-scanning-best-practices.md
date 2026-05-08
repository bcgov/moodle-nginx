# 🔒 Security Scanning Best Practices

## 📋 Executive Summary

**Current State:** Shift-left controls are active in `checkEnv` with pre-build validation and branch-aware preflight dependency gating.
**Recommended State:** Continue hardening with targeted post-build and observability improvements.
**Benefits:**
- ⚡ Faster feedback (don't build if supply chain is compromised)
- 💰 Cost savings (avoid building vulnerable images)
- 🛡️ Better security posture (block before Artifactory push)

**Configuration:** For environment-specific settings, scan levels, and complete implementation guide, see [Security Scanning Configuration Guide](./security-scanning-configuration.md).

**Architecture Review:** For alignment with existing systems and redundancy analysis, see [Security Scanning Review](./security-scanning-review.md).

---

## 🎯 Recommended 3-Phase Security Strategy

### **Phase 1: Pre-Build Supply Chain Validation** ⭐ **CRITICAL**
**Location:** `checkEnv` job (before image builds)
**Duration:** ~2-3 minutes
**Exit Strategy:** **BLOCK on CRITICAL vulnerabilities**

#### What to Scan:
1. ✅ **Base Docker Images** (`php:8.1-fpm`, `nginx:alpine`, etc.)
   - Scan with Trivy before using in Dockerfiles
   - Validates supply chain integrity

2. ✅ **PHP/Composer Dependencies** (from `composer.json`)
   - Run `composer audit` on dependency manifest
   - Check for known CVEs in declared versions

3. ✅ **Git Repository Security Advisories**
   - Query GitHub API for security advisories
   - Check Moodle.org for known vulnerabilities

4. ✅ **System Package Intentions** (from Dockerfiles)
   - Parse `apt-get install` commands
   - Check if packages have known vulnerabilities

#### Why Pre-Build?
- **Fail Fast:** Don't waste 10-15 minutes building if supply chain is compromised
- **Cost Efficient:** GitHub Actions minutes are expensive
- **Immediate Feedback:** Developers know immediately if their dependency updates have security issues

#### Example Output:
```
=== 🔒 PRE-BUILD SECURITY VALIDATION ===
✅ Base Images: php:8.1-fpm (0 critical, 2 high)
✅ Composer Dependencies: 45 packages scanned (0 critical, 0 high)
⚠️  Git Advisories: moodle/moodle@MOODLE_401_STABLE (1 advisory - review recommended)
✅ System Packages: All packages up to date

Overall Status: WARNINGS (0 critical, 1 warning)
✅ Safe to proceed with image builds
```

---

### **Phase 2: Post-Build Image Validation** ⭐ **IMPORTANT**
**Location:** After each image build (moodle, cron, web)
**Duration:** ~3-5 minutes per image
**Exit Strategy:** **BLOCK push to Artifactory on CRITICAL**

#### What to Scan:
1. ✅ **Built Container Images**
   - Scan the actual `moodle:latest` image after build
   - Validates complete supply chain (base + your layers)

2. ✅ **Installed Packages in Container**
   - Scan what actually ended up in the final image
   - Catches issues from multi-stage builds

#### Implementation:
```yaml
- name: Build Moodle Image
  run: docker build -t moodle:latest -f Moodle.Dockerfile .

- name: Scan Moodle Image
  run: |
    trivy image --severity CRITICAL,HIGH moodle:latest
    if [ $? -ne 0 ]; then
      echo "❌ CRITICAL vulnerabilities found in built image"
      exit 1
    fi

- name: Push to Artifactory
  run: docker push artifacts.developer.gov.bc.ca/moodle:latest
```

#### Why Post-Build?
- **Comprehensive:** Validates the complete image, not just intentions
- **Catches Build-Time Issues:** Some vulnerabilities only appear after package installation
- **Prevents Bad Images:** Don't push vulnerable images to Artifactory

---

### Phase 3: Post-Deploy Application Security (~5 minutes) ⚠️

**Goal**: Validate deployed application security, skip redundant container scans

**When**: After successful deployment to OpenShift

**What to Scan**:

✅ **NPM dependencies FIRST** (config/lighthouse packages) - **Supply chain attack prevention**
✅ Runtime application security (Lighthouse + OWASP checks)
❌ **Skip**: Container image re-scanning (already done in Phase 2)
❌ **Skip**: System package re-scanning (already done in Phase 1)
❌ **Skip**: Composer re-scanning (already done in Phase 1)

**Exit Strategy**: WARN only (deployment already completed)

**Tools**:
- **NPM audit** for lighthouse dependencies (run FIRST before Lighthouse execution)
- Lighthouse CI (performance, accessibility, security headers)
- OWASP ZAP / Security headers scan

**Why This Order**:
- **NPM packages scanned BEFORE Lighthouse runs** to prevent supply chain attacks
- Application already deployed (can't roll back automatically)
- Report issues for next deployment
- Focus on runtime security, not build-time

**Important**: Always validate NPM dependencies before executing any testing tools that may access live applications.

---

## 🚀 Performance Optimizations

### 1. **Cache Trivy Vulnerability Database**
```yaml
- name: Cache Trivy DB
  uses: actions/cache@v4
  with:
    path: ~/.cache/trivy
    key: trivy-db-${{ runner.os }}-${{ github.run_id }}
    restore-keys: trivy-db-${{ runner.os }}-
```
**Savings:** ~30-60 seconds per job

### 2. **Parallel Image Scans**
```yaml
strategy:
  matrix:
    image: [moodle, cron, web]
jobs:
  scan-images:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        image: ${{ strategy.matrix.image }}
```
**Savings:** 3x faster (3 minutes vs 9 minutes)

### 3. **Skip Unchanged Base Images**
```yaml
- name: Check if base image changed
  id: base-check
  run: |
    LAST_SCAN=$(cat .cache/last-php-scan.txt || echo "never")
    CURRENT="php:8.1-fpm"
    if [ "$LAST_SCAN" == "$CURRENT" ]; then
      echo "skip=true" >> $GITHUB_OUTPUT
    fi

- name: Scan Base Image
  if: steps.base-check.outputs.skip != 'true'
  run: trivy image php:8.1-fpm
```
**Savings:** ~1-2 minutes when base images unchanged

### 4. **Fail Fast on First CRITICAL**
```bash
scan_result=$(trivy image --severity CRITICAL --exit-code 1 myimage:latest)
if [ $? -ne 0 ]; then
  echo "❌ CRITICAL found - stopping all scans"
  exit 1
fi
```
**Savings:** Stop immediately, don't waste time scanning remaining images

---

## 📊 Comparison: Current vs Recommended

| Phase | Current Approach | Recommended Approach | Time Saved |
|-------|-----------------|---------------------|------------|
| **Pre-Build** | ❌ No pre-build scan | ✅ Scan supply chain first | +2-3 min (but saves 10-15 min on failures) |
| **Build** | ⏱️ Build all images | ⏱️ Build only if pre-build passes | 0 min (same) |
| **Post-Build** | ❌ No post-build scan | ✅ Scan built images before push | +3-5 min |
| **Post-Deploy** | ✅ Scan everything again | ✅ Lighthouse only (skip redundant) | **-5-8 min saved** |
| **Total** | ~20-25 minutes | ~18-22 minutes | **3-8 min faster** |

### Additional Benefits:
- **Fail Fast:** If supply chain is compromised, know in 2-3 minutes (not 20+ minutes)
- **Cost Savings:** Avoid building images if they'll fail security scan anyway
- **Better Security:** Don't push vulnerable images to Artifactory

---

## 🎯 Recommended Workflow Structure

```yaml
jobs:
  checkEnv:
    steps:
      - Install Trivy + Docker
      - Auto-populate dependencies
      - PHP Compatibility Check
      - 🔒 PRE-BUILD SECURITY SCAN (Phase 1) ⭐
        - Scan base images
        - Scan Composer dependencies
        - Check Git advisories
        - Exit: BLOCK if CRITICAL

  moodle-build:
    needs: [checkEnv]  # Only runs if security passes
    steps:
      - Build Moodle image
      - 🔒 SCAN BUILT IMAGE (Phase 2) ⭐
      - Push to Artifactory only if scan passes

  deploy:
    needs: [moodle-build, ...]

  lighthouse-check:
    needs: [deploy]
    steps:
      - 📊 LIGHTHOUSE AUDIT (Phase 3)
      - NPM security scan
      - Skip redundant container scans
```

---

## 🛠️ Implementation Checklist

### Immediate Actions:
- [x] Move Trivy installation to `checkEnv` job (before builds)
- [x] Add pre-build security scan function call in `checkEnv`
- [x] Configure scan to enforce branch-aware fail-fast behavior
- [ ] Add explicit post-build image scan assertions after each Docker build
- [ ] Remove redundant container scans from `lighthouse-check` where applicable

### Future Enhancements:
- [ ] Cache Trivy vulnerability database
- [ ] Implement parallel image scanning
- [ ] Add base image change detection
- [ ] Create security scan result dashboard
- [ ] Set up automated security notifications

---

## 📝 Example: Pre-Build Security Scan Call

```yaml
- name: 🔒 Pre-Build Security Validation
  id: security-scan
  run: |
    echo "=== 🔒 PRE-BUILD SECURITY VALIDATION ==="

    # Source utility functions
    source openshift/scripts/utils/github-actions.sh

    # Run comprehensive pre-build security scan
    # Parameters: project_dir, scan_level, abort_on, scan_images
    if ! run_comprehensive_security_scan "." "moderate" "CRITICAL" "true"; then
      echo "❌ CRITICAL: Pre-build security scan failed"
      echo "SECURITY_STATUS=❌ CRITICAL ISSUES" >> $GITHUB_OUTPUT
      exit 1  # Block the build
    fi

    echo "SECURITY_STATUS=✅ PASSED" >> $GITHUB_OUTPUT
    echo "✅ Pre-build security validation passed - safe to build images"
```

---

## 🔍 Troubleshooting

### Issue: Trivy Not Found
**Solution:** Install Trivy in `checkEnv` job before security scans
```yaml
- name: Install Trivy
  run: |
    sudo apt-get update
    sudo apt-get install -y trivy
    trivy --version
```

### Issue: Docker Not Available
**Solution:** Add Docker Buildx setup
```yaml
- name: Set up Docker Buildx
  uses: docker/setup-buildx-action@v2
```

### Issue: Lighthouse Config Not Found
**Problem:** GitHub Actions redacts "lighthouse" as `***` in logs
**Solution:** The directory exists, ignore the redacted logs. Path resolution works correctly.

---

## 📚 References

- [Trivy Documentation](https://aquasecurity.github.io/trivy/)
- [Docker Security Best Practices](https://docs.docker.com/develop/security-best-practices/)
- [OWASP Container Security](https://owasp.org/www-project-docker-top-10/)
- [Shift Left Security](https://www.devsecops.org/blog/2021/02/17/what-is-shift-left-security)

---

**Last Updated:** November 6, 2025
**Author:** Senior DevOps Team
**Status:** ✅ Recommended for Implementation
