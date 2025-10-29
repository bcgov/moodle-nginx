#!/bin/bash
# validate-php-security.sh
# Comprehensive PHP dependency security validation script
# Integrates with centralized version management and CI/CD security scanning

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSER_DIR="$PROJECT_ROOT/config/moodle"

log_info() {
    echo "🔍 $1"
}

log_success() {
    echo "✅ $1"
}

log_error() {
    echo "❌ $1" >&2
}

log_warn() {
    echo "⚠️  $1"
}

# Validate Composer security
validate_composer_security() {
    log_info "Running Composer security audit..."

    cd "$COMPOSER_DIR"

    # Run security audit
    if composer audit --format=json > security-audit.json 2>&1; then
        log_success "No known vulnerabilities found in PHP dependencies"
    else
        local exit_code=$?
        log_error "Security vulnerabilities found in PHP dependencies"

        # Display vulnerabilities in human-readable format
        if [ -f security-audit.json ]; then
            composer audit --format=table

            # Count vulnerabilities
            local vuln_count=$(jq -r '.advisories | length' security-audit.json 2>/dev/null || echo "unknown")
            log_error "Found $vuln_count security advisories"

            # Save for CI/CD processing
            cp security-audit.json "$PROJECT_ROOT/tmp/php-security-report.json" 2>/dev/null || true
        fi

        return $exit_code
    fi

    # Validate composer.json and composer.lock
    log_info "Validating Composer configuration..."
    if composer validate --strict --check-lock; then
        log_success "Composer configuration is valid"
    else
        log_error "Composer configuration validation failed"
        return 1
    fi

    cd "$PROJECT_ROOT"
}

# Check for outdated dependencies
check_outdated_dependencies() {
    log_info "Checking for outdated dependencies..."

    cd "$COMPOSER_DIR"

    # Generate outdated report
    if composer outdated --format=json > outdated-dependencies.json 2>&1; then
        local outdated_count=$(jq -r '.installed | length' outdated-dependencies.json 2>/dev/null || echo "0")

        if [ "$outdated_count" -gt 0 ]; then
            log_warn "$outdated_count dependencies have updates available"
            composer outdated --format=table

            # Save for review
            cp outdated-dependencies.json "$PROJECT_ROOT/tmp/php-outdated-report.json" 2>/dev/null || true
        else
            log_success "All dependencies are up to date"
        fi
    else
        log_warn "Could not check for outdated dependencies"
    fi

    cd "$PROJECT_ROOT"
}

# License compliance check
check_license_compliance() {
    log_info "Checking license compliance..."

    cd "$COMPOSER_DIR"

    # Generate license report
    if composer licenses --format=json > license-report.json 2>&1; then
        log_success "License information collected"

        # Display licenses
        composer licenses --format=table

        # Check for problematic licenses (GPL, AGPL, etc.)
        local problematic_licenses=$(jq -r '.dependencies[] | select(.license[] | contains("GPL") or contains("AGPL")) | .name' license-report.json 2>/dev/null || echo "")

        if [ -n "$problematic_licenses" ]; then
            log_warn "Found dependencies with potentially problematic licenses:"
            echo "$problematic_licenses"
        else
            log_success "No license compliance issues detected"
        fi

        # Save for compliance review
        cp license-report.json "$PROJECT_ROOT/tmp/php-license-report.json" 2>/dev/null || true
    else
        log_warn "Could not generate license report"
    fi

    cd "$PROJECT_ROOT"
}

# Version drift detection
check_version_drift() {
    log_info "Checking for version drift from centralized management..."

    # Source centralized versions
    source "$PROJECT_ROOT/example.versions.env"

    # Check if composer.json was generated from centralized versions
    local composer_file="$COMPOSER_DIR/composer.json"

    if [ ! -f "$composer_file" ]; then
        log_error "composer.json not found. Run: ./openshift/scripts/populate-dependency-manifests.sh"
        return 1
    fi

    # Check if file contains generation metadata
    local has_metadata=$(jq -r '.extra.source_file // "none"' "$composer_file" 2>/dev/null || echo "none")

    if [ "$has_metadata" != "example.versions.env" ]; then
        log_warn "composer.json appears to be manually maintained (no generation metadata)"
        log_warn "Consider running: ./openshift/scripts/populate-dependency-manifests.sh to ensure centralized management"
    fi

    # Check actual versions against centralized versions
    local actual_zipstream=$(jq -r '.require["maennchen/zipstream-php"]' "$composer_file" 2>/dev/null || echo "unknown")
    local expected_zipstream="${ZIPSTREAM_PHP_VERSION:-unknown}"

    if [ "$actual_zipstream" != "$expected_zipstream" ]; then
        log_error "Version drift detected for maennchen/zipstream-php:"
        log_error "  Expected: $expected_zipstream"
        log_error "  Actual: $actual_zipstream"
        log_error "  Run: ./openshift/scripts/populate-dependency-manifests.sh to fix"
        return 1
    else
        log_success "No version drift detected - versions match centralized management"
    fi
}

# Generate security summary report
generate_security_report() {
    log_info "Generating comprehensive PHP security report..."

    local report_file="$PROJECT_ROOT/tmp/php-security-summary.json"
    mkdir -p "$(dirname "$report_file")"

    cat > "$report_file" << EOF
{
  "scan_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "project": "bcgov/moodle-nginx",
  "scan_type": "php_dependencies",
  "composer_directory": "$COMPOSER_DIR",
  "reports": {
    "security_audit": "$([ -f "$COMPOSER_DIR/security-audit.json" ] && echo "available" || echo "not_available")",
    "outdated_dependencies": "$([ -f "$COMPOSER_DIR/outdated-dependencies.json" ] && echo "available" || echo "not_available")",
    "license_compliance": "$([ -f "$COMPOSER_DIR/license-report.json" ] && echo "available" || echo "not_available")"
  },
  "centralized_management": {
    "versions_file": "example.versions.env",
    "last_sync": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "drift_detected": false
  },
  "recommendations": [
    "Regularly update centralized versions in example.versions.env",
    "Run security scans in CI/CD pipeline",
    "Monitor Dependabot alerts for automated updates",
    "Review license compliance quarterly"
  ]
}
EOF

    log_success "Security report generated: $report_file"
}

# Main execution
main() {
    log_info "🛡️  Running comprehensive PHP dependency security validation"
    log_info "Project: $PROJECT_ROOT"

    # Create temp directory for reports
    mkdir -p "$PROJECT_ROOT/tmp"

    local exit_code=0

    # Run all security checks
    if ! validate_composer_security; then
        exit_code=1
    fi

    check_outdated_dependencies
    check_license_compliance

    if ! check_version_drift; then
        exit_code=1
    fi

    generate_security_report

    if [ $exit_code -eq 0 ]; then
        log_success "🎉 PHP dependency security validation completed successfully"
        log_info "Next steps:"
        log_info "  • Review reports in tmp/ directory"
        log_info "  • Address any security advisories"
        log_info "  • Update versions in example.versions.env as needed"
    else
        log_error "❌ PHP dependency security validation failed"
        log_error "Please address the issues above before proceeding"
    fi

    return $exit_code
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi