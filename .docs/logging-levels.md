# Three-Tier Logging System

## Overview

Our CI/CD pipeline uses a **three-tier logging system** to balance visibility with readability:

```yaml
DEBUG_LEVEL: "INFO"   # Production default - clean logs
DEBUG_LEVEL: "DEBUG"  # Development - show debug messages
DEBUG_LEVEL: "TRACE"  # Troubleshooting - full verbosity + command tracing
```

---

## Log Levels Explained

### 📊 INFO (Default - Production)

**Purpose**: Clean, actionable logs for normal operation

**What You See**:

- ✅ Success messages
- ⚠️ Warnings
- ❌ Errors
- ℹ️ Key milestones (e.g., "Starting deployment", "Security scan passed")

**What You DON'T See**:

- Internal function parameters
- Cache hit/miss details
- File paths being processed
- Intermediate calculation steps

**Example Output**:

```bash
ℹ️  Running comprehensive security scan...
ℹ️  Strategy: Git Dependencies + Base Images + Post-Build Scanning
ℹ️  🔍 Phase 3: Git Dependencies Security
✅ Security scan passed - no critical issues detected
```

**Use When**:
- Production deployments (950003-prod)
- Test environment (950003-test)
- Normal development (950003-dev)
- CI/CD logs for stakeholder review

---

### 🔍 DEBUG (Development)

**Purpose**: Show internal logic for understanding pipeline behavior

**What You See** (in addition to INFO):

- 🔍 Function entry/exit points
- 🔍 Configuration values being used
- 🔍 Decision branches taken
- 🔍 Resource availability checks

**What You DON'T See**:

- Command tracing (set -x output)
- Raw API responses
- Ultra-verbose iteration logs

**Example Output**:

```bash
ℹ️  Running comprehensive security scan...
🔍 Debug: Skipping containerized scans to avoid duplicate builds
ℹ️  Strategy: Git Dependencies + Base Images + Post-Build Scanning
🔍 Debug: Checking GitHub security advisories: bcgov/moodle @ MOODLE_405_STABLE
ℹ️  🔍 Phase 3: Git Dependencies Security
✅ Security scan passed - no critical issues detected
🔍 Debug: Cached security scan results for future builds
```

### 🔬 TRACE (Deep Troubleshooting)

**Purpose**: Maximum verbosity for diagnosing complex issues

**What You See** (in addition to DEBUG):

- 🔬 Every bash command executed (set -x)
- 🔬 Variable expansion details
- 🔬 Cache age calculations
- 🔬 Temporary file operations
- 🔬 Loop iterations

**Example Output**:

```bash
++ DEBUG_LEVEL=TRACE
++ '[' TRACE = TRACE ']'
++ set -x
🔬 TRACE mode enabled - full command tracing active
ℹ️  Running comprehensive security scan...
🔬 Trace: Project: /home/runner/work/moodle-nginx, Level: basic, Abort on critical: false
++ test -f tmp/comprehensive-security-summary.json
🔬 Trace: No cached security results found, running full scan
++ local overall_status=CLEAN
++ local critical_issues=0
🔍 Debug: Checking GitHub security advisories: bcgov/moodle @ MOODLE_405_STABLE
++ curl -s --max-time 10 https://api.github.com/repos/bcgov/moodle/security-advisories
++ jq -r '.errors // [] | length'
✅ Security scan passed - no critical issues detected
🔬 Trace: Cached security scan results for future builds
```

**Use When**:

- Bash script failures with unclear cause
- Command substitution issues
- Race conditions or timing problems
- Investigating cache behavior
- Step-by-step execution analysis

**⚠️ Warning**: TRACE logs can be **10-50x larger** than INFO logs!

---

## Implementation Details

### Log Functions

```bash
# Always shown (regardless of DEBUG_LEVEL)
log_info()  # ℹ️  General information
log_warn()  # ⚠️  Warnings
log_error() # ❌ Errors

# Shown when DEBUG_LEVEL=DEBUG or TRACE
log_debug() # 🔍 Debug: Internal logic, decisions, parameters

# Shown only when DEBUG_LEVEL=TRACE
log_trace() # 🔬 Trace: Ultra-verbose details, cache operations
```

### Command Tracing (set -x)

**Enabled when**: `DEBUG_LEVEL=TRACE`

**Disabled when**: `DEBUG_LEVEL=INFO` or `DEBUG_LEVEL=DEBUG`

**Location**: Applied in GitHub Actions workflow steps:

```yaml
- name: 🚦 Lighthouse Performance Audit
  run: |
    # Enable command tracing only when TRACE level debugging
    if [ "${{ needs.checkEnv.outputs.DEBUG_LEVEL }}" = "TRACE" ]; then
      set -x
      echo "🔬 TRACE mode enabled - full command tracing active"
    fi

    # ... rest of script
```

---

## Configuration per Environment

### Development (950003-dev)

```yaml
env:
  DEBUG_LEVEL: "DEBUG"  # Show debug messages during active development
```

**Rationale**:

- Understand what's happening without overwhelming logs
- Quick iteration with meaningful feedback
- Easier to spot issues in logs

---

### Test (950003-test)

```yaml
env:
  DEBUG_LEVEL: "INFO"  # Clean logs for test validation
```

**Rationale**:

- Test environment mirrors production
- Clean logs for QA review
- Use DEBUG temporarily when investigating issues

---

### Production (950003-prod)

```yaml
env:
  DEBUG_LEVEL: "INFO"  # Production-grade clean logs
```

**Rationale**:

- Stakeholder-friendly output
- Audit trail without clutter
- Performance (less I/O)

---

## When to Change DEBUG_LEVEL

### Temporarily Enable DEBUG

**Scenario**: Investigating why a specific job failed

**Steps**:

1. Edit `.github/workflows/build.yml` in your branch
2. Change `DEBUG_LEVEL: "INFO"` → `DEBUG_LEVEL: "DEBUG"`
3. Commit and push
4. Review logs for 🔍 Debug messages
5. Revert to INFO after issue resolved

---

### Temporarily Enable TRACE

**Scenario**: Bash script error with unclear root cause

**Steps**:

1. Edit `.github/workflows/build.yml` in your branch
2. Change `DEBUG_LEVEL: "DEBUG"` → `DEBUG_LEVEL: "TRACE"`
3. ⚠️ **Warning**: Be prepared for LARGE logs
4. Commit and push
5. Download full logs from GitHub Actions
6. Search for errors around `set -x` output
7. **MUST revert to DEBUG or INFO** after troubleshooting

---

## Log Size Comparison

| Level | Typical Size | Build Time Impact |
|-------|-------------|------------------|
| **INFO** | 10-20 KB | None (baseline) |
| **DEBUG** | 50-100 KB | Negligible (~1-2s) |
| **TRACE** | 500 KB - 2 MB | Minor (~5-10s) |

**Note**: GitHub Actions has a 10 MB log limit per job. TRACE mode typically stays well below this.

---

## Troubleshooting Examples

### Example 1: Security Scan Failing

**Symptom**: "Security scan failed" but no details

**Solution**:
```yaml
DEBUG_LEVEL: "DEBUG"  # Enable debug messages
```

**Expected Output**:
```bash
🔍 Debug: Checking GitHub security advisories: bcgov/moodle @ MOODLE_405_STABLE
❌ Found 2 published security advisories for bcgov/moodle
⚠️  Review: https://github.com/bcgov/moodle/security/advisories
```

---

### Example 2: Bash Script Syntax Error

**Symptom**: "line 42: syntax error near unexpected token"

**Solution**:

```yaml
DEBUG_LEVEL: "TRACE"  # Enable command tracing
```

**Expected Output**:

```bash
++ local cache_age_seconds=
++ date +%s
+ cache_age_seconds=$((1699876543 - ))
/opt/actions-runner/_work/_temp/12345.sh: line 42: syntax error near unexpected token `)'
```

**Root Cause**: Empty variable in arithmetic expansion

---

### Example 3: Cache Not Restoring

**Symptom**: "No cached security results found" every run

**Solution**:

```yaml
DEBUG_LEVEL: "DEBUG"  # Check cache logic
```

**Expected Output**:

```bash
🔍 Debug: Cache key: linux-security-abc123def456
ℹ️  ✓ Found valid cached security scan (3600s old, max 86400s)
ℹ️    Using cached results to speed up build
```

**Root Cause**: If debug shows "No cached security results found", check GitHub Actions cache settings.

---

## Quick Reference

| Need | Use Level | What You'll See |
|------|-----------|-----------------|
| Normal build | INFO | Success/errors only |
| Understand logic | DEBUG | + Internal decisions |
| Diagnose bash errors | TRACE | + Command execution |
| Audit trail | INFO | Clean, stakeholder-friendly |
| Development iteration | DEBUG | Balance of visibility & readability |

---

## Related Documentation

- [Security Scanning Optimization](.docs/security-scanning-optimization.md)
- [Lighthouse Performance Testing](.docs/lighthouse-performance.md)
- [GitHub Actions Best Practices](.docs/github-actions-best-practices.md)

---

## Changelog

### 2025-11-07
- ✅ Implemented three-tier logging system (INFO/DEBUG/TRACE)
- ✅ Added `log_trace()` function for ultra-verbose messages
- ✅ Made command tracing conditional on TRACE level
- ✅ Migrated cache operations to use log_trace()
- ✅ Updated build.yml with level documentation
