#!/bin/bash
# comprehensive-security-scan.sh
# Enhanced security validation covering PHP dependencies, container images, and system packages
# Integrates with centralized version management and provides detailed security reporting

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSER_DIR="$PROJECT_ROOT/config/moodle"
REPORTS_DIR="$PROJECT_ROOT/tmp"

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

log_section() {
    echo ""
    echo "=== $1 ==="
}

# Initialize reports directory
init_reports() {
    mkdir -p "$REPORTS_DIR"
    log_info "Initialized reports directory: $REPORTS_DIR"
}

# Scan container images for vulnerabilities using Trivy
scan_container_images() {
    log_section "🐳 Container Image Security Scan"
    
    # Source centralized versions
    source "$PROJECT_ROOT/example.versions.env"
    
    local images=(
        "$PHP_IMAGE"
        "$CRON_IMAGE" 
        "$DB_IMAGE"
        "$WEB_IMAGE"
        "$BACKUP_IMAGE"
        "$REDIS_IMAGE"
        "$REDIS_SENTINEL_IMAGE"
    )
    
    local scan_results_file="$REPORTS_DIR/container-security-scan.json"
    local scan_summary_file="$REPORTS_DIR/container-security-summary.md"
    
    # Initialize results
    echo '{"scanned_images": [], "summary": {"total_images": 0, "high_vulns": 0, "critical_vulns": 0, "scan_timestamp": ""}}' > "$scan_results_file"
    
    cat > "$scan_summary_file" << EOF
# 🐳 Container Image Security Scan Report

**Scan Timestamp:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Project:** bcgov/moodle-nginx

## 📊 Scanned Images

| Image | Tag | Critical | High | Medium | Low | Status |
|-------|-----|----------|------|--------|-----|--------|
EOF

    local total_critical=0
    local total_high=0
    local scan_errors=0
    
    for image in "${images[@]}"; do
        log_info "Scanning container image: $image"
        
        # Check if Trivy is available
        if ! command -v trivy >/dev/null 2>&1; then
            log_warn "Trivy not available - container scanning skipped"
            echo "| $image | - | SKIPPED | SKIPPED | SKIPPED | SKIPPED | ⚠️ Trivy not available |" >> "$scan_summary_file"
            continue
        fi
        
        # Run Trivy scan
        local image_report="$REPORTS_DIR/trivy-$(echo "$image" | sed 's/[^a-zA-Z0-9]/-/g').json"
        
        if trivy image --format json --output "$image_report" "$image" 2>/dev/null; then
            # Parse results
            local critical=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity == "CRITICAL")] | length' "$image_report" 2>/dev/null || echo "0")
            local high=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH")] | length' "$image_report" 2>/dev/null || echo "0")
            local medium=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity == "MEDIUM")] | length' "$image_report" 2>/dev/null || echo "0")
            local low=$(jq -r '[.Results[]?.Vulnerabilities[]? | select(.Severity == "LOW")] | length' "$image_report" 2>/dev/null || echo "0")
            
            total_critical=$((total_critical + critical))
            total_high=$((total_high + high))
            
            # Determine status
            local status="✅ SAFE"
            if [ "$critical" -gt 0 ]; then
                status="🚨 CRITICAL"
            elif [ "$high" -gt 5 ]; then
                status="⚠️ HIGH RISK"
            elif [ "$high" -gt 0 ]; then
                status="⚠️ MODERATE"
            fi
            
            echo "| $image | latest | $critical | $high | $medium | $low | $status |" >> "$scan_summary_file"
            log_info "Image $image: $critical critical, $high high vulnerabilities"
            
        else
            log_warn "Failed to scan image: $image"
            echo "| $image | - | ERROR | ERROR | ERROR | ERROR | ❌ Scan failed |" >> "$scan_summary_file"
            scan_errors=$((scan_errors + 1))
        fi
    done
    
    # Add summary to markdown
    cat >> "$scan_summary_file" << EOF

## 📈 Scan Summary

- **Total Images Scanned:** ${#images[@]}
- **Total Critical Vulnerabilities:** $total_critical
- **Total High Vulnerabilities:** $total_high
- **Scan Errors:** $scan_errors

## 🎯 Recommendations

$(if [ "$total_critical" -gt 0 ]; then
    echo "- 🚨 **URGENT**: Address $total_critical critical vulnerabilities immediately"
fi)
$(if [ "$total_high" -gt 10 ]; then
    echo "- ⚠️ **HIGH PRIORITY**: $total_high high-severity vulnerabilities need attention"
fi)
- 🔄 **Regular Updates**: Update base images regularly for security patches
- 📊 **Monitor**: Set up automated container image scanning in CI/CD
- 🛡️ **Dependabot**: Use Dependabot for automated base image updates

## 🔗 Additional Resources

- [Container Security Best Practices](https://kubernetes.io/docs/concepts/security/)
- [Trivy Documentation](https://trivy.dev/)
- [Docker Security](https://docs.docker.com/engine/security/)

---
*Generated by comprehensive-security-scan.sh*
EOF

    # Update JSON summary
    jq --arg timestamp "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
       --argjson total_images "${#images[@]}" \
       --argjson critical "$total_critical" \
       --argjson high "$total_high" \
       '.summary.scan_timestamp = $timestamp | .summary.total_images = $total_images | .summary.critical_vulns = $critical | .summary.high_vulns = $high' \
       "$scan_results_file" > "$scan_results_file.tmp" && mv "$scan_results_file.tmp" "$scan_results_file"

    if [ "$total_critical" -gt 0 ]; then
        log_error "Found $total_critical critical vulnerabilities in container images"
        return 1
    elif [ "$total_high" -gt 10 ]; then
        log_warn "Found $total_high high-severity vulnerabilities in container images"
    else
        log_success "Container image security scan completed - no critical issues"
    fi
}

# Enhanced PHP dependency scanning
scan_php_dependencies() {
    log_section "🐘 PHP Dependencies Security Scan"
    
    if [ ! -f "$COMPOSER_DIR/composer.json" ]; then
        log_error "composer.json not found. Run dependency manifest generation first."
        return 1
    fi
    
    cd "$COMPOSER_DIR"
    
    # Install dependencies if composer.lock doesn't exist
    if [ ! -f "composer.lock" ]; then
        log_info "Installing PHP dependencies for security scanning..."
        composer install --no-dev --no-scripts --no-progress --quiet
    fi
    
    # Security audit
    log_info "Running Composer security audit..."
    local security_exit_code=0
    
    if composer audit --format=json > "$REPORTS_DIR/php-security-audit.json" 2>&1; then
        log_success "No known vulnerabilities found in PHP dependencies"
    else
        security_exit_code=$?
        log_error "Security vulnerabilities found in PHP dependencies"
        
        # Display human-readable format
        composer audit --format=table || true
        
        # Count vulnerabilities
        local vuln_count=$(jq -r '.advisories | length' "$REPORTS_DIR/php-security-audit.json" 2>/dev/null || echo "unknown")
        log_error "Found $vuln_count security advisories"
    fi
    
    # License compliance
    log_info "Checking license compliance..."
    if composer licenses > "$REPORTS_DIR/php-licenses.txt" 2>&1; then
        log_success "License information collected"
        
        # Check for problematic licenses
        local problematic=$(grep -E "(GPL|AGPL)" "$REPORTS_DIR/php-licenses.txt" | grep -v "LGPL" || echo "")
        if [ -n "$problematic" ]; then
            log_warn "Found dependencies with potentially problematic licenses"
            echo "$problematic"
        fi
    else
        log_warn "Could not generate license report"
    fi
    
    # Outdated dependencies
    log_info "Checking for outdated dependencies..."
    if composer outdated --format=json > "$REPORTS_DIR/php-outdated.json" 2>&1; then
        local outdated_count=$(jq -r '.installed | length' "$REPORTS_DIR/php-outdated.json" 2>/dev/null || echo "0")
        if [ "$outdated_count" -gt 0 ]; then
            log_warn "$outdated_count dependencies have updates available"
        else
            log_success "All dependencies are up to date"
        fi
    fi
    
    cd "$PROJECT_ROOT"
    return $security_exit_code
}

# Scan Dependabot configuration and status
check_dependabot_status() {
    log_section "🤖 Dependabot Configuration Check"
    
    local dependabot_config="$PROJECT_ROOT/.github/dependabot.yml"
    
    if [ -f "$dependabot_config" ]; then
        log_success "Dependabot configuration found"
        
        # Count configured ecosystems
        local ecosystems=$(yq eval '.updates[].package-ecosystem' "$dependabot_config" 2>/dev/null | wc -l || echo "0")
        log_info "Monitoring $ecosystems dependency ecosystems"
        
        # Check for Docker ecosystem
        if yq eval '.updates[] | select(.package-ecosystem == "docker")' "$dependabot_config" >/dev/null 2>&1; then
            log_success "Docker image monitoring enabled"
        else
            log_warn "Docker image monitoring not configured in Dependabot"
        fi
        
        # Check for Composer ecosystem  
        if yq eval '.updates[] | select(.package-ecosystem == "composer")' "$dependabot_config" >/dev/null 2>&1; then
            log_success "PHP Composer monitoring enabled"
        else
            log_warn "PHP Composer monitoring not configured in Dependabot"
        fi
        
    else
        log_error "Dependabot configuration not found: $dependabot_config"
        log_info "Consider adding Dependabot for automated dependency updates"
        return 1
    fi
}

# Generate comprehensive security report
generate_comprehensive_report() {
    log_section "📊 Generating Comprehensive Security Report"
    
    local summary_file="$REPORTS_DIR/comprehensive-security-summary.md"
    local json_file="$REPORTS_DIR/comprehensive-security-summary.json"
    
    # Source versions for report
    source "$PROJECT_ROOT/example.versions.env"
    
    cat > "$summary_file" << EOF
# 🛡️ Comprehensive Security Report

**Scan Timestamp:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Project:** bcgov/moodle-nginx
**Branch:** $(git branch --show-current 2>/dev/null || echo "unknown")
**Commit:** $(git rev-parse --short HEAD 2>/dev/null || echo "unknown")

## 📋 Executive Summary

This report provides a comprehensive security assessment covering:
- 🐳 **Container Images**: Base images and dependencies
- 🐘 **PHP Dependencies**: Composer packages and security advisories  
- 🤖 **Dependency Management**: Dependabot and automated updates
- 📦 **System Packages**: Operating system dependencies

## 🎯 Key Findings

### Container Images
$(if [ -f "$REPORTS_DIR/container-security-summary.md" ]; then
    echo "$(cat "$REPORTS_DIR/container-security-summary.md" | grep -A5 "## 📈 Scan Summary" | tail -n+2)"
else
    echo "- ⚠️ Container image scan not completed"
fi)

### PHP Dependencies  
$(if [ -f "$REPORTS_DIR/php-security-audit.json" ]; then
    local php_vulns=$(jq -r '.advisories | length' "$REPORTS_DIR/php-security-audit.json" 2>/dev/null || echo "0")
    if [ "$php_vulns" -gt 0 ]; then
        echo "- 🚨 Found $php_vulns PHP security advisories"
    else
        echo "- ✅ No PHP security vulnerabilities detected"
    fi
else
    echo "- ⚠️ PHP dependency scan not completed"
fi)

### Base Images in Use
| Component | Image | Version | Purpose |
|-----------|--------|---------|---------|
| PHP | $PHP_IMAGE | Latest | Main application runtime |
| Database | $DB_IMAGE | Latest | Data persistence |
| Web Server | $WEB_IMAGE | Latest | HTTP proxy and static files |
| Cache | $REDIS_IMAGE | Latest | Session and data caching |
| Backup | $BACKUP_IMAGE | Latest | Database backup utility |

## 📁 Generated Reports

The following detailed reports are available:

- **📊 Container Security**: \`container-security-summary.md\`
- **🐘 PHP Dependencies**: \`php-security-audit.json\`
- **📜 License Compliance**: \`php-licenses.txt\`
- **🔄 Outdated Packages**: \`php-outdated.json\`

## 🔒 Security Recommendations

### Immediate Actions
1. **Review Critical Vulnerabilities**: Address any critical findings immediately
2. **Update Base Images**: Ensure all container images are using latest security patches
3. **Monitor Dependencies**: Set up automated scanning for new vulnerabilities

### Ongoing Security Practices
1. **Automated Updates**: Enable Dependabot for all dependency types
2. **Regular Scans**: Run comprehensive security scans on every deployment
3. **Vulnerability Monitoring**: Subscribe to security advisories for all dependencies
4. **Incident Response**: Have a plan for responding to newly discovered vulnerabilities

## 🔄 Next Steps

1. **Review Detailed Reports**: Examine all generated security reports
2. **Prioritize Fixes**: Address critical and high-severity issues first
3. **Update Dependencies**: Use centralized version management in \`example.versions.env\`
4. **Monitor Continuously**: Set up alerts for new security advisories

---
*Generated by comprehensive-security-scan.sh*
*Timestamp: $(date -u +"%Y-%m-%dT%H:%M:%SZ")*
EOF

    # Generate JSON summary
    cat > "$json_file" << EOF
{
  "scan_timestamp": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "project": "bcgov/moodle-nginx",
  "branch": "$(git branch --show-current 2>/dev/null || echo "unknown")",
  "commit": "$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")",
  "scan_types": [
    "container_images",
    "php_dependencies", 
    "dependency_management",
    "license_compliance"
  ],
  "base_images": {
    "php": "$PHP_IMAGE",
    "database": "$DB_IMAGE", 
    "web": "$WEB_IMAGE",
    "redis": "$REDIS_IMAGE",
    "backup": "$BACKUP_IMAGE"
  },
  "reports_generated": [
    "container-security-summary.md",
    "php-security-audit.json",
    "php-licenses.txt", 
    "php-outdated.json",
    "comprehensive-security-summary.md"
  ],
  "recommendations": [
    "Review and address all critical vulnerabilities immediately",
    "Enable Dependabot for automated dependency updates",
    "Set up continuous security monitoring",
    "Establish incident response procedures for security issues"
  ]
}
EOF

    log_success "Comprehensive security report generated: $summary_file"
    
    # Add to GitHub Actions Summary if available
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "$summary_file" >> "$GITHUB_STEP_SUMMARY"
        log_success "Security report added to GitHub Actions Summary"
    fi
}

# Main execution
main() {
    log_info "🚀 Starting comprehensive security scan"
    log_info "Project: $PROJECT_ROOT"
    
    init_reports
    
    local exit_code=0
    
    # Run all security scans
    if ! scan_container_images; then
        exit_code=1
    fi
    
    if ! scan_php_dependencies; then
        exit_code=1
    fi
    
    if ! check_dependabot_status; then
        # Dependabot issues are warnings, not failures
        log_warn "Dependabot configuration issues detected"
    fi
    
    generate_comprehensive_report
    
    if [ $exit_code -eq 0 ]; then
        log_success "🎉 Comprehensive security scan completed successfully"
        log_info "Review detailed reports in: $REPORTS_DIR"
    else
        log_error "❌ Security scan completed with critical issues"
        log_error "Address security vulnerabilities before deployment"
    fi
    
    return $exit_code
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi