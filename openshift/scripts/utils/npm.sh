#!/bin/bash

# NPM Security Utilities Module
# Contains NPM vulnerability scanning, supply chain attack detection, and dependency management

# =============================================================================
# SECURITY SCANNING
# =============================================================================
# Note: Manual compromised package lists removed in favor of:
# - Dependabot: Automated security updates (weekly, auto-merge security patches)
# - NPM Audit: Real-time vulnerability scanning with GitHub Security Advisory database
# - These tools provide better coverage and automatic updates vs static lists

# =============================================================================
# LIGHTHOUSE-SPECIFIC SECURITY SCANNING
# =============================================================================

# Lighthouse security scan with warning-only behavior
# Lighthouse is testing-only but handles sensitive credentials/URLs
lighthouse_security_scan() {
  local project_dir="${1:-.}"
  local audit_level="${2:-moderate}"

  log_info "Running Lighthouse NPM security scan (warning-only mode)..."
  log_info "Note: Lighthouse handles credentials/URLs but is testing-only"
  log_debug "Project: $project_dir, Audit level: $audit_level"

  cd "$project_dir" || return 1

  # Initialize result variables
  local audit_result=""
  local overall_status="PASS"

  # Run NPM audit (primary security check)
  npm_audit_scan "$project_dir" "$audit_level" "audit_result"
  local audit_exit=$?

  # Determine status but always continue (warning-only)
  if [ "$audit_result" = "CRITICAL" ]; then
    overall_status="WARNING_CRITICAL"
    log_warn "🔒 LIGHTHOUSE SECURITY WARNING: Critical vulnerabilities detected!"
    log_warn "   This is a warning (not blocking) as Lighthouse is testing-only"
    log_warn "   However, credentials/URLs are involved - please review ASAP"
  elif [ "$audit_result" = "HIGH" ]; then
    overall_status="WARNING_HIGH"
    log_warn "🔒 LIGHTHOUSE SECURITY WARNING: High-severity vulnerabilities detected!"
  elif [ "$audit_result" = "MODERATE" ] || [ "$audit_result" = "LOW" ]; then
    overall_status="PASS_WITH_LOW_PRIORITY"
    log_info "✅ Lighthouse NPM security scan: Only low/moderate vulnerabilities (below threshold)"
  elif [ "$audit_result" = "CLEAN" ]; then
    overall_status="PASS"
    log_info "✅ Lighthouse NPM security scan: No vulnerabilities detected"
  else
    overall_status="UNKNOWN"
    log_warn "⚠️ Lighthouse NPM security scan: Unable to determine status"
  fi

  # Generate summary
  local package_count=0
  if [ -f "package-lock.json" ] && command -v jq >/dev/null 2>&1; then
    package_count=$(jq '.packages | length' package-lock.json 2>/dev/null || echo "unknown")
  fi

  log_info "Lighthouse Security Summary:"
  log_info "  NPM Audit: $audit_result"
  log_info "  Status: $overall_status (warnings only - testing environment)"
  log_info "  Total Packages: $package_count"
  log_info "  Security Updates: Automated via Dependabot (weekly)"

  # Always return success (warning-only mode)
  return 0
}

# =============================================================================
# MAIN NPM SECURITY SCANNING
# =============================================================================

npm_audit_scan() {
  local project_dir="${1:-.}"
  local audit_level="${2:-moderate}"
  local output_var="${3:-AUDIT_RESULT}"

  log_info "Running NPM security audit in: $project_dir"
  log_info "Using GitHub Security Advisory database (auto-updated)"

  cd "$project_dir" || return 1

  local audit_file="/tmp/npm-audit-$(date +%s).json"
  local exit_code=0

  # Run npm audit and capture exit code (npm audit exits 1 if vulnerabilities found)
  npm audit --audit-level "$audit_level" --json > "$audit_file" 2>/dev/null || exit_code=$?

  # Parse JSON output to determine actual vulnerability counts
  if command -v jq >/dev/null 2>&1 && [ -f "$audit_file" ]; then
    local critical=$(jq -r '.metadata.vulnerabilities.critical // 0' "$audit_file" 2>/dev/null || echo "0")
    local high=$(jq -r '.metadata.vulnerabilities.high // 0' "$audit_file" 2>/dev/null || echo "0")
    local moderate=$(jq -r '.metadata.vulnerabilities.moderate // 0' "$audit_file" 2>/dev/null || echo "0")
    local low=$(jq -r '.metadata.vulnerabilities.low // 0' "$audit_file" 2>/dev/null || echo "0")

    log_debug "Vulnerability breakdown: Critical=$critical, High=$high, Moderate=$moderate, Low=$low"

    # Check actual counts, not just npm exit code
    if [ "$critical" -gt 0 ]; then
      eval "$output_var='CRITICAL'"
      log_error "CRITICAL: $critical critical vulnerabilities found!"
      rm -f "$audit_file"
      return 2
    elif [ "$high" -gt 0 ]; then
      eval "$output_var='HIGH'"
      log_warn "WARNING: $high high-severity vulnerabilities found!"
      rm -f "$audit_file"
      return 1
    elif [ "$moderate" -gt 0 ]; then
      eval "$output_var='MODERATE'"
      log_info "MODERATE: $moderate moderate vulnerabilities found (below $audit_level threshold)"
      rm -f "$audit_file"
      return 0
    elif [ "$low" -gt 0 ]; then
      eval "$output_var='LOW'"
      log_info "LOW: $low low-severity vulnerabilities found (below $audit_level threshold)"
      rm -f "$audit_file"
      return 0
    else
      # All counts are zero - truly clean
      eval "$output_var='CLEAN'"
      log_info "No vulnerabilities found"
      rm -f "$audit_file"
      return 0
    fi
  else
    # Fallback if jq not available or file parsing failed
    if [ $exit_code -eq 0 ]; then
      log_info "No $audit_level+ vulnerabilities found"
      eval "$output_var='CLEAN'"
    else
      log_warn "Vulnerabilities may exist but could not parse audit output"
      eval "$output_var='UNKNOWN'"
    fi
  fi

  rm -f "$audit_file"
  return $exit_code
}

# =============================================================================
# COMPREHENSIVE SECURITY SCAN
# =============================================================================

npm_security_scan() {
  local project_dir="${1:-.}"
  local audit_level="${2:-moderate}"
  local abort_on_critical="${3:-true}"

  log_info "Running comprehensive NPM security scan..."
  log_info "Leveraging: NPM Audit + GitHub Security Advisory + Dependabot"
  log_debug "Project: $project_dir, Audit level: $audit_level, Abort on critical: $abort_on_critical"

  cd "$project_dir" || return 1

  # Initialize result variables
  local audit_result=""
  local overall_status="PASS"

  # Run NPM audit (now our primary security check)
  npm_audit_scan "$project_dir" "$audit_level" "audit_result"
  local audit_exit=$?

  # Determine overall status based on audit results
  if [ "$audit_result" = "CRITICAL" ]; then
    overall_status="CRITICAL_FAIL"
    log_error "CRITICAL: Critical vulnerabilities detected!"
  elif [ "$audit_result" = "HIGH" ]; then
    overall_status="WARNING"
    log_warn "HIGH: High-severity vulnerabilities detected!"
  elif [ "$audit_exit" -ne 0 ]; then
    overall_status="WARNING"
  fi

  # Generate summary
  local package_count=0
  if [ -f "package-lock.json" ] && command -v jq >/dev/null 2>&1; then
    package_count=$(jq '.packages | length' package-lock.json 2>/dev/null || echo "unknown")
  fi

  log_info "Security Scan Summary:"
  log_info "  NPM Audit: $audit_result"
  log_info "  Overall Status: $overall_status"
  log_info "  Total Packages: $package_count"
  log_info "  Security Updates: Automated via Dependabot (weekly)"

  # Determine exit code
  case "$overall_status" in
    "CRITICAL_FAIL")
      if [ "$abort_on_critical" = "true" ]; then
        log_error "Build aborted due to critical security issues!"
        log_error "Note: Dependabot should prevent most issues via auto-updates"
        return 2
      else
        return 1
      fi
      ;;
    "WARNING")
      log_warn "Consider running 'npm audit fix' or waiting for Dependabot updates"
      return 1
      ;;
    *)
      return 0
      ;;
  esac
}

# =============================================================================
# CACHE OPTIMIZATION
# =============================================================================

get_npm_cache_info() {
  local project_dir="${1:-.}"

  log_debug "Gathering NPM cache information..."

  cd "$project_dir" || return 1

  local npm_cache_size="unknown"
  local node_modules_size="unknown"
  local package_hash="unknown"
  local lockfile_exists="false"

  # Get cache sizes
  if [ -d "$HOME/.npm" ]; then
    npm_cache_size=$(du -sh "$HOME/.npm" 2>/dev/null | cut -f1 || echo "unknown")
  fi

  if [ -d "node_modules" ]; then
    node_modules_size=$(du -sh "node_modules" 2>/dev/null | cut -f1 || echo "unknown")
  fi

  # Get package info
  if [ -f "package.json" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      package_hash=$(sha256sum package.json | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
      package_hash=$(shasum -a 256 package.json | cut -d' ' -f1)
    fi
  fi

  if [ -f "package-lock.json" ]; then
    lockfile_exists="true"
  fi

  log_info "NPM Cache Information:"
  log_info "  NPM global cache: $npm_cache_size"
  log_info "  Node modules: $node_modules_size"
  log_info "  Package hash: ${package_hash:0:12}..."
  log_info "  Lockfile exists: $lockfile_exists"
}

# =============================================================================
# INSTALL WITH SECURITY VALIDATION
# =============================================================================

npm_install_secure() {
  local project_dir="${1:-.}"
  local use_ci="${2:-auto}"
  local security_check="${3:-true}"

  log_info "Installing NPM dependencies with security validation..."
  log_info "Security: NPM Audit + Dependabot protection active"

  cd "$project_dir" || return 1

  # Pre-install security check using NPM audit (no manual lists)
  if [ "$security_check" = "true" ]; then
    log_info "Running pre-install security validation..."

    # Use NPM audit for security validation
    if [ -f "package.json" ]; then
      # Pass "." since we've already changed to project_dir
      npm_audit_scan "." "high" "PREINSTALL_RESULT"
      if [ $? -eq 2 ]; then
        log_error "Pre-install security check failed!"
        log_error "Run 'npm audit fix' or check Dependabot for updates"
        return 2
      fi
    fi
  fi

  # Determine install method
  local install_cmd="npm install"
  if [ "$use_ci" = "auto" ]; then
    if [ -f "package-lock.json" ]; then
      install_cmd="npm ci"
      log_debug "Using 'npm ci' (lockfile found)"
    else
      install_cmd="npm install"
      log_debug "Using 'npm install' (no lockfile)"
    fi
  elif [ "$use_ci" = "true" ]; then
    install_cmd="npm ci"
  fi

  # Install dependencies
  log_info "Running: $install_cmd"
  if $install_cmd; then
    log_info "Dependencies installed successfully"
  else
    log_error "Failed to install dependencies"
    return 1
  fi

  # Post-install security check
  if [ "$security_check" = "true" ]; then
    log_info "Running post-install security validation..."
    # Pass "." since we've already changed to project_dir
    npm_security_scan "." "moderate" "true"
    return $?
  fi

  return 0
}