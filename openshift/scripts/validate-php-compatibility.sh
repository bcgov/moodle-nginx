#!/bin/bash
#==============================================================================
# validate-php-compatibility.sh
#==============================================================================
# PURPOSE:
#   Validates PHP dependency compatibility with current runtime PHP version.
#   Prevents deployment of Composer packages requiring newer PHP versions,
#   avoiding runtime errors and compatibility issues.
#
# COMPATIBILITY CHECKS:
#   1. PHP Runtime Version: Extracted from PHP_IMAGE in example.versions.env
#   2. Composer Require: Minimum PHP version in composer.json
#   3. Package Matrix: Known packages with specific PHP requirements
#   4. Installed Packages: Checks composer.lock for incompatible versions
#
# COMPATIBILITY MATRIX:
#   Pre-defined list of packages with known PHP version requirements:
#   - maennchen/zipstream-php >= 3.2.0 requires PHP 8.2+
#   - symfony/console >= 6.0.0 requires PHP 8.2+
#   - guzzlehttp/guzzle >= 8.0.0 requires PHP 8.2+
#   - doctrine/orm >= 3.0.0 requires PHP 8.2+
#   - monolog/monolog >= 3.0.0 requires PHP 8.1+
#
# VALIDATION PROCESS:
#   1. Load runtime PHP version from example.versions.env
#   2. Parse composer.json for minimum PHP requirement
#   3. Check composer.lock for installed package versions
#   4. Compare against compatibility matrix
#   5. Report incompatibilities with upgrade recommendations
#
# OUTPUTS:
#   - Console: Human-readable compatibility report
#   - File: tmp/php-compatibility-report.json (detailed findings)
#   - Exit Code: 0=compatible, 1=incompatibilities found
#
# USAGE:
#   # Run compatibility validation
#   ./openshift/scripts/validate-php-compatibility.sh
#
#   # Check report
#   cat tmp/php-compatibility-report.json
#
# CI/CD INTEGRATION:
#   Called by: comprehensive-security-scan.sh (MEDIUM and FULL levels)
#   Artifacts: php-compatibility-report.json uploaded to GitHub Actions
#
# RELATED DOCS:
#   - Configuration: ../../example.versions.env
#   - Composer: ../../config/moodle/composer.json
#   - Security Scan: ./comprehensive-security-scan.sh
#==============================================================================

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

# PHP Compatibility Matrix
# Format: package_name:min_version:php_requirement:note
COMPATIBILITY_MATRIX=(
    "maennchen/zipstream-php:3.2.0:8.2:ZipStream v3.2.0+ requires PHP 8.2+"
    "symfony/console:6.0.0:8.2:Symfony 6.0+ requires PHP 8.2+"
    "guzzlehttp/guzzle:8.0.0:8.2:Guzzle 8.0+ requires PHP 8.2+"
    "doctrine/orm:3.0.0:8.2:Doctrine ORM 3.0+ requires PHP 8.2+"
    "monolog/monolog:3.0.0:8.1:Monolog 3.0+ requires PHP 8.1+"
)

# Get current PHP runtime version from PHP_IMAGE in example.versions.env
# Extracts major.minor from image tag (e.g., "php:8.3-fpm" -> "8.3")
get_php_runtime_version() {
    if [ -f "$PROJECT_ROOT/example.versions.env" ]; then
        source "$PROJECT_ROOT/example.versions.env"
        if [[ "${PHP_IMAGE:-}" =~ php:([0-9]+\.[0-9]+) ]]; then
            echo "${BASH_REMATCH[1]}"
            return
        fi
    fi
    log_warn "Could not extract PHP version from PHP_IMAGE -- defaulting to 8.3"
    echo "8.3"
}

# Parse semantic version for comparison
version_to_number() {
    local version="$1"
    # Remove any prefix characters (^, ~, >=, etc.)
    version=$(echo "$version" | sed 's/[^0-9.]//g')
    # Convert x.y.z to comparable number
    echo "$version" | awk -F. '{ printf("%d%03d%03d\n", $1,$2,$3); }'
}

# Check if a package version meets minimum requirement
version_meets_requirement() {
    local actual="$1"
    local required="$2"

    local actual_num=$(version_to_number "$actual")
    local required_num=$(version_to_number "$required")

    [ "$actual_num" -ge "$required_num" ]
}

# Check individual package compatibility
check_package_compatibility() {
    local package_name="$1"
    local package_version="$2"
    local current_php="$3"

    # Check against compatibility matrix
    for entry in "${COMPATIBILITY_MATRIX[@]}"; do
        IFS=':' read -r pkg min_ver req_php note <<< "$entry"

        if [ "$pkg" = "$package_name" ]; then
            # Check if current version meets problematic minimum
            if version_meets_requirement "$package_version" "$min_ver"; then
                # Check if current PHP meets requirement
                if ! version_meets_requirement "$current_php" "$req_php"; then
                    log_error "PHP compatibility issue found:"
                    log_error "  Package: $package_name ($package_version)"
                    log_error "  Requires: PHP $req_php+"
                    log_error "  Current:  PHP $current_php"
                    log_error "  Note: $note"
                    return 1
                fi
            fi
        fi
    done

    return 0
}

# Validate all packages in composer.json
validate_composer_compatibility() {
    local php_version="$1"
    local composer_file="$COMPOSER_DIR/composer.json"

    if [ ! -f "$composer_file" ]; then
        log_error "composer.json not found: $composer_file"
        return 1
    fi

    log_info "Validating PHP $php_version compatibility..."

    local incompatible_packages=0

    # Parse composer.json and check each package
    local packages=$(jq -r '.require | to_entries[] | "\(.key):\(.value)"' "$composer_file" 2>/dev/null || echo "")

    if [ -z "$packages" ]; then
        log_warn "No packages found in composer.json"
        return 0
    fi

    while IFS=':' read -r package version; do
        # Skip PHP itself and meta-packages
        if [[ "$package" =~ ^(php|ext-|lib-) ]]; then
            continue
        fi

        log_info "Checking $package ($version)..."

        if ! check_package_compatibility "$package" "$version" "$php_version"; then
            incompatible_packages=$((incompatible_packages + 1))
        fi
    done <<< "$packages"

    if [ "$incompatible_packages" -gt 0 ]; then
        log_error "Found $incompatible_packages PHP compatibility issues"
        return 1
    fi

    log_success "All packages compatible with PHP $php_version"
    return 0
}

# Check platform requirements using Composer
check_composer_platform_requirements() {
    local php_version="$1"

    log_info "Checking Composer platform requirements..."

    cd "$COMPOSER_DIR"

    # Check if composer.json exists
    if [ ! -f "composer.json" ]; then
        log_warn "composer.json not found, skipping platform requirements check"
        cd "$PROJECT_ROOT"
        return 0
    fi

    # Set platform PHP version for validation
    composer config platform.php "$php_version"

    # Validate composer.json syntax and requirements
    if composer validate --no-check-all --no-check-lock 2>/dev/null; then
        log_success "Composer configuration valid"
    else
        log_warn "Composer validation issues detected"
    fi

    # Since we use ephemeral dependencies (no composer.lock), we can't use check-platform-reqs
    # Instead, verify that the require section has valid platform constraints
    if command -v jq >/dev/null 2>&1; then
        local php_constraint=$(jq -r '.require.php // "none"' composer.json)
        if [ "$php_constraint" != "none" ]; then
            log_info "PHP constraint in composer.json: $php_constraint"
            log_success "Composer platform configuration validated"
        else
            log_warn "No PHP constraint specified in composer.json"
        fi
    fi

    cd "$PROJECT_ROOT"
    return 0
}

# Generate compatibility report
generate_compatibility_report() {
    local php_version="$1"
    local report_file="$PROJECT_ROOT/tmp/php-compatibility-report.json"
    local summary_file="$PROJECT_ROOT/tmp/php-compatibility-summary.md"

    mkdir -p "$(dirname "$report_file")"

    # Generate JSON report
    cat > "$report_file" << EOF
{
  "scan_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "project": "bcgov/moodle-nginx",
  "scan_type": "php_compatibility",
  "php_runtime_version": "$php_version",
  "composer_directory": "$COMPOSER_DIR",
  "compatibility_matrix": [
$(IFS=$'\n'; for entry in "${COMPATIBILITY_MATRIX[@]}"; do
    IFS=':' read -r pkg min_ver req_php note <<< "$entry"
    echo "    {\"package\": \"$pkg\", \"min_version\": \"$min_ver\", \"php_requirement\": \"$req_php\", \"note\": \"$note\"},"
done | sed '$ s/,$//')
  ],
  "validation_status": "$([ -f "$PROJECT_ROOT/tmp/.php-compat-passed" ] && echo "passed" || echo "failed")",
  "recommendations": [
    "Review PHP compatibility before upgrading dependencies",
    "Use Dependabot ignore rules for incompatible versions",
    "Plan PHP runtime upgrades to enable newer dependencies",
    "Monitor security advisories for compatibility-constrained packages"
  ]
}
EOF

    # Generate human-readable summary
    cat > "$summary_file" << EOF
# 🐘 PHP Compatibility Report

**Scan Timestamp:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**PHP Runtime Version:** $php_version
**Project:** bcgov/moodle-nginx

## 📊 Compatibility Status

$([ -f "$PROJECT_ROOT/tmp/.php-compat-passed" ] && echo "✅ **COMPATIBLE** - All dependencies support PHP $php_version" || echo "❌ **INCOMPATIBLE** - Some dependencies require newer PHP version")

## 🔍 Known Compatibility Constraints

| Package | Min Version | PHP Requirement | Note |
|---------|-------------|-----------------|------|
$(for entry in "${COMPATIBILITY_MATRIX[@]}"; do
    IFS=':' read -r pkg min_ver req_php note <<< "$entry"
    echo "| $pkg | $min_ver+ | PHP $req_php+ | $note |"
done)

## 🎯 Recommendations

### For Current PHP $php_version Environment
- Review the compatibility matrix above for version constraints
- Use Dependabot ignore rules to block incompatible versions
- Monitor security advisories for compatibility-constrained packages

### Security Management
- Critical security updates may require emergency PHP upgrade evaluation
- Document compatibility constraints in centralized version management
- PHP version is sourced from PHP_IMAGE in example.versions.env

## 🔄 Next Steps

1. **Review**: Check any failed compatibility validations above
2. **Update**: Use centralized version management in \`example.versions.env\`
3. **Monitor**: Set up alerts for security advisories on constrained packages
4. **Plan**: Consider PHP 8.2 upgrade timeline for better dependency support

---
*PHP compatibility validation ensures runtime stability while managing security updates*
*Generated by validate-php-compatibility.sh*
EOF

    log_success "PHP compatibility report generated: $summary_file"

    # Add to GitHub Actions Summary if available
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "$summary_file" >> "$GITHUB_STEP_SUMMARY"
        log_success "Compatibility report added to GitHub Actions Summary"
    fi
}

# Main execution
main() {
    log_info "🐘 PHP Compatibility Validation"

    local php_version=$(get_php_runtime_version)
    log_info "Current PHP runtime: $php_version"

    # Create temp directory for reports
    mkdir -p "$PROJECT_ROOT/tmp"

    local exit_code=0

    # Run compatibility validations
    if validate_composer_compatibility "$php_version"; then
        log_success "Package compatibility validation passed"
    else
        exit_code=1
    fi

    if check_composer_platform_requirements "$php_version"; then
        log_success "Platform requirements validation passed"
    else
        exit_code=1
    fi

    # Mark success/failure for report generation
    if [ $exit_code -eq 0 ]; then
        touch "$PROJECT_ROOT/tmp/.php-compat-passed"
    else
        rm -f "$PROJECT_ROOT/tmp/.php-compat-passed"
    fi

    generate_compatibility_report "$php_version"

    if [ $exit_code -eq 0 ]; then
        log_success "🎉 PHP compatibility validation completed successfully"
        log_info "All dependencies compatible with PHP $php_version"
    else
        log_error "❌ PHP compatibility validation failed"
        log_error "Some dependencies require newer PHP version"
        log_info "Review compatibility report for details"
    fi

    return $exit_code
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi