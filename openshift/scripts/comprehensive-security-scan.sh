#!/bin/bash
#==============================================================================
# comprehensive-security-scan.sh
#==============================================================================
# PURPOSE:
#   Orchestrates comprehensive security scanning across multiple dimensions:
#   PHP dependencies, container images (Trivy), and code quality. Provides
#   environment-aware configuration for CI/CD and local development.
#
# SCAN LEVELS:
#   OFF     - Skip all security scanning
#   BASIC   - PHP security audit only (composer audit)
#   MEDIUM  - BASIC + PHP compatibility checks
#   FULL    - MEDIUM + container image scanning (Trivy)
#
# EXIT ON SEVERITY:
#   CRITICAL - Exit only on critical vulnerabilities
#   HIGH     - Exit on high or critical (default)
#   MEDIUM   - Exit on medium, high, or critical
#   LOW      - Exit on any vulnerability
#   NEVER    - Always succeed (report only)
#
# CONFIGURATION:
#   SECURITY_SCAN_ENABLED    - YES/NO (default: YES)
#   SECURITY_SCAN_LEVEL      - OFF/BASIC/MEDIUM/FULL (default: BASIC)
#   SECURITY_SCAN_EXIT_ON    - CRITICAL/HIGH/MEDIUM/LOW/NEVER (default: HIGH)
#   SECURITY_SCAN_CONTAINERS - YES/NO scan container images (default: NO)
#   SECURITY_SCAN_CACHE      - YES/NO use vulnerability cache (default: YES)
#
# ARCHITECTURE:
#   1. Read configuration from environment (set in build.yml)
#   2. Call validate-php-security.sh for Composer audit
#   3. Call validate-php-compatibility.sh for version checks
#   4. Run Trivy container scanning if FULL level
#   5. Aggregate results and determine exit code based on EXIT_ON setting
#
# USAGE:
#   # Run with defaults (BASIC level, exit on HIGH)
#   ./openshift/scripts/comprehensive-security-scan.sh
#
#   # Run FULL scan with container images
#   export SECURITY_SCAN_LEVEL=FULL
#   export SECURITY_SCAN_CONTAINERS=YES
#   ./openshift/scripts/comprehensive-security-scan.sh
#
# CI/CD INTEGRATION:
#   Called by: .github/workflows/build.yml (scan job)
#   Configuration: Environment variables set in workflow
#   Artifacts: All security reports uploaded to GitHub Actions
#
# RELATED DOCS:
#   - PHP Security: ./validate-php-security.sh
#   - PHP Compatibility: ./validate-php-compatibility.sh
#   - Security Utilities: ./utils/security.sh
#   - CI/CD: ../../.github/workflows/build.yml
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source utility functions with error checking
if [ -f "$SCRIPT_DIR/utils/security.sh" ]; then
  source "$SCRIPT_DIR/utils/security.sh"
else
  echo "❌ Error: security.sh not found at $SCRIPT_DIR/utils/security.sh"
  exit 1
fi

if [ -f "$SCRIPT_DIR/utils/openshift.sh" ]; then
  source "$SCRIPT_DIR/utils/openshift.sh"
else
  echo "❌ Error: openshift.sh not found at $SCRIPT_DIR/utils/openshift.sh"
  exit 1
fi

# Read configuration from environment variables (set in build.yml)
SCAN_ENABLED="${SECURITY_SCAN_ENABLED:-YES}"
SCAN_LEVEL="${SECURITY_SCAN_LEVEL:-BASIC}"
EXIT_ON="${SECURITY_SCAN_EXIT_ON:-HIGH}"
SCAN_CONTAINERS="${SECURITY_SCAN_CONTAINERS:-NO}"
USE_CACHE="${SECURITY_SCAN_CACHE:-YES}"

# Early exit if disabled
if [[ "$SCAN_ENABLED" != "YES" ]]; then
  echo "🔒 Security scanning disabled (SECURITY_SCAN_ENABLED!=YES)"
  exit 0
fi

if [[ "$SCAN_LEVEL" == "OFF" ]]; then
  echo "🔒 Security scanning skipped (SECURITY_SCAN_LEVEL=OFF)"
  exit 0
fi

log_info "🔒 Security Scan Configuration:"
log_info "  Enabled: $SCAN_ENABLED"
log_info "  Level: $SCAN_LEVEL"
log_info "  Exit On: $EXIT_ON"
log_info "  Container Scanning: $SCAN_CONTAINERS"
log_info "  Use Cache: $USE_CACHE"

# Convert SCAN_CONTAINERS to boolean for comprehensive_security_scan function
SCAN_CONTAINERS_BOOL="false"
if [[ "$SCAN_CONTAINERS" == "YES" ]]; then
  SCAN_CONTAINERS_BOOL="true"
fi

# Convert EXIT_ON to abort_on_critical parameter
ABORT_ON_CRITICAL="true"
if [[ "$EXIT_ON" == "WARN" ]]; then
  ABORT_ON_CRITICAL="false"
fi

# Run scans based on level
case "$SCAN_LEVEL" in
  MINIMAL)
    log_info "Running MINIMAL security scan (~1 min, critical advisories only)"
    comprehensive_security_scan "$PROJECT_ROOT" "minimal" "$ABORT_ON_CRITICAL" "false"
    ;;
  BASIC)
    log_info "Running BASIC security scan (~3 min, supply chain + dependencies)"
    comprehensive_security_scan "$PROJECT_ROOT" "basic" "$ABORT_ON_CRITICAL" "false"
    ;;
  FULL)
    log_info "Running FULL security scan (~8 min, comprehensive + containers)"
    comprehensive_security_scan "$PROJECT_ROOT" "full" "$ABORT_ON_CRITICAL" "$SCAN_CONTAINERS_BOOL"
    ;;
  *)
    log_warn "⚠️ Unknown SECURITY_SCAN_LEVEL: $SCAN_LEVEL, defaulting to BASIC"
    comprehensive_security_scan "$PROJECT_ROOT" "basic" "$ABORT_ON_CRITICAL" "false"
    ;;
esac

SCAN_EXIT=$?

# Map exit codes to user-friendly messages
if [ $SCAN_EXIT -eq 0 ]; then
  log_success "✅ Security scan PASSED - no blocking issues found"
  exit 0
elif [ $SCAN_EXIT -eq 1 ]; then
  if [[ "$EXIT_ON" == "WARN" ]]; then
    log_info "⚠️ Security warnings found (WARN mode - not failing build)"
    exit 0
  else
    log_warn "⚠️ Security issues found but below blocking threshold"
    exit 0
  fi
elif [ $SCAN_EXIT -eq 2 ]; then
  if [[ "$EXIT_ON" == "WARN" ]]; then
    log_error "❌ CRITICAL security issues found (WARN mode - not failing build)"
    exit 0
  else
    log_error "❌ CRITICAL security issues found - build BLOCKED"
    log_error "Review security scan results above and apply fixes"
    exit 2
  fi
else
  log_error "❌ Security scan failed with unexpected exit code: $SCAN_EXIT"
  exit 2
fi
