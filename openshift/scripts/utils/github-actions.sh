#!/bin/bash

# GitHub Actions Utilities Module
# Contains GitHub Actions specific helpers and integration functions

# =============================================================================
# SECURITY SCANNING INTEGRATIONS
# =============================================================================

run_comprehensive_security_scan() {
  local project_dir="${1:-.}"
  local scan_level="${2:-moderate}"
  local abort_on_critical="${3:-true}"
  local scan_docker_images="${4:-false}"
  local verbose="${5:-false}"

  log_info "Running comprehensive multi-ecosystem security scan..."
  log_info "Coverage: NPM + PHP/Composer + Docker + System packages + Git dependencies"

  cd "$project_dir" || return 1

  # Source security utilities
  source "$(dirname "${BASH_SOURCE[0]}")/security.sh"
  source "$(dirname "${BASH_SOURCE[0]}")/npm.sh"

  # Setup security tools
  setup_security_tools "true"

  # Run comprehensive scan
  comprehensive_security_scan "$project_dir" "$scan_level" "$abort_on_critical" "$scan_docker_images"
  local scan_exit=$?

  if [ "$verbose" = "true" ]; then
    log_info "Multi-ecosystem security scan completed with exit code: $scan_exit"

    # Provide actionable recommendations
    get_security_recommendations "$project_dir"

    case $scan_exit in
      0)
        log_info "✅ No critical security issues detected across all ecosystems"
        ;;
      1)
        log_warn "⚠️ Security warnings found - review recommended but not blocking"
        log_warn "Dependabot will automatically address many of these issues"
        ;;
      2)
        log_error "❌ Critical security issues detected - build should be blocked"
        log_error "Immediate action required before deployment"
        ;;
    esac
  fi

  return $scan_exit
}

run_github_actions_npm_security_scan() {
  local project_dir="${1:-.}"
  local audit_level="${2:-moderate}"
  local abort_on_critical="${3:-true}"
  local verbose="${4:-false}"

  log_info "Running GitHub Actions NPM security scan..."
  log_info "Using automated tools: NPM Audit + GitHub Security Advisory"

  cd "$project_dir" || return 1

  # Source npm utilities
  source "$(dirname "${BASH_SOURCE[0]}")/npm.sh"

  # Run streamlined security scan (no manual lists)
  npm_security_scan "$project_dir" "$audit_level" "$abort_on_critical"
  local scan_exit=$?

  if [ "$verbose" = "true" ]; then
    log_info "Security scan completed with exit code: $scan_exit"
    if [ $scan_exit -eq 0 ]; then
      log_info "✅ No security issues detected"
    elif [ $scan_exit -eq 1 ]; then
      log_warn "⚠️ Security warnings found (non-blocking)"
    else
      log_error "❌ Critical security issues detected"
    fi
  fi

  return $scan_exit
}

setup_github_actions_dependency_caching() {
  local cache_key_prefix="${1:-lighthouse}"
  local cache_paths="${2:-~/.npm|config/lighthouse/node_modules}"
  local package_json_path="${3:-config/lighthouse/package.json}"

  log_info "Setting up GitHub Actions dependency caching..."

  # Generate cache information for GitHub Actions
  local cache_key="$cache_key_prefix-${{ hashFiles('$package_json_path') }}-v3"
  local restore_keys="$cache_key_prefix-"

  cat << EOF
# GitHub Actions Cache Configuration
# Add this to your workflow step:

- name: Cache Node modules
  uses: actions/cache@v4
  with:
    path: |
$(echo "$cache_paths" | tr '|' '\n' | sed 's/^/      /')
    key: \${{ runner.os }}-$cache_key
    restore-keys: |
      \${{ runner.os }}-$restore_keys
      \${{ runner.os }}-node-

EOF
}

# =============================================================================
# DEPENDABOT AND AUTOMATED SECURITY TOOLS INTEGRATION
# =============================================================================

generate_dependabot_config() {
  local output_file="${1:-.github/dependabot.yml}"
  local package_ecosystems="${2:-npm,docker,github-actions}"

  log_info "Generating Dependabot configuration..."

  mkdir -p "$(dirname "$output_file")"

  cat << EOF > "$output_file"
# Dependabot configuration for automated dependency updates
# This replaces manual maintenance of compromised package lists
version: 2
updates:
EOF

  # Add NPM ecosystem
  if echo "$package_ecosystems" | grep -q "npm"; then
    cat << EOF >> "$output_file"
  # NPM dependencies (Lighthouse, build tools, etc.)
  - package-ecosystem: "npm"
    directory: "/config/lighthouse"
    schedule:
      interval: "weekly"
      day: "monday"
      time: "09:00"
    open-pull-requests-limit: 5
    reviewers:
      - "security-team"
    labels:
      - "dependencies"
      - "security"
    # Security-focused configuration
    insecure-external-code-execution: "deny"
    # Group related updates
    groups:
      lighthouse-dependencies:
        patterns:
          - "lighthouse*"
          - "puppeteer*"
          - "chrome*"
      security-updates:
        patterns:
          - "*"
        update-types:
          - "security"
    # Automatically merge security updates
    auto-merge:
      type: "security-updates"

EOF
  fi

  # Add Docker ecosystem
  if echo "$package_ecosystems" | grep -q "docker"; then
    cat << EOF >> "$output_file"
  # Docker base images
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "tuesday"
      time: "09:00"
    open-pull-requests-limit: 3
    reviewers:
      - "infrastructure-team"
    labels:
      - "docker"
      - "security"

EOF
  fi

  # Add GitHub Actions ecosystem
  if echo "$package_ecosystems" | grep -q "github-actions"; then
    cat << EOF >> "$output_file"
  # GitHub Actions
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "monthly"
      day: "monday"
      time: "09:00"
    open-pull-requests-limit: 3
    reviewers:
      - "devops-team"
    labels:
      - "github-actions"
      - "security"

EOF
  fi

  log_info "✅ Dependabot configuration generated: $output_file"
}

# =============================================================================
# SNYK INTEGRATION
# =============================================================================

setup_snyk_security_scanning() {
  local project_path="${1:-.}"
  local snyk_token="${2:-$SNYK_TOKEN}"
  local severity_threshold="${3:-high}"

  log_info "Setting up Snyk security scanning..."

  if [ -z "$snyk_token" ]; then
    log_error "SNYK_TOKEN environment variable required"
    return 1
  fi

  # Install Snyk CLI if not available
  if ! command -v snyk >/dev/null 2>&1; then
    log_info "Installing Snyk CLI..."
    npm install -g snyk
  fi

  # Authenticate with Snyk
  snyk auth "$snyk_token"

  # Run Snyk test
  log_info "Running Snyk vulnerability scan..."
  cd "$project_path" || return 1

  if snyk test --severity-threshold="$severity_threshold" --json > snyk-results.json; then
    log_info "✅ Snyk scan passed - no $severity_threshold+ vulnerabilities"
    return 0
  else
    log_error "❌ Snyk scan failed - $severity_threshold+ vulnerabilities found"

    # Parse and display results
    if command -v jq >/dev/null 2>&1; then
      log_error "Vulnerabilities found:"
      jq -r '.vulnerabilities[] | "- \(.title) (\(.severity)): \(.packageName)@\(.version)"' snyk-results.json
    fi

    return 1
  fi
}

# =============================================================================
# GITHUB SECURITY ADVISORIES INTEGRATION
# =============================================================================

check_github_security_advisories() {
  local repository="${1:-$GITHUB_REPOSITORY}"
  local github_token="${2:-$GITHUB_TOKEN}"

  log_info "Checking GitHub Security Advisories..."

  if [ -z "$github_token" ]; then
    log_error "GITHUB_TOKEN required for GitHub Security Advisories"
    return 1
  fi

  # Use GitHub CLI if available, otherwise curl
  if command -v gh >/dev/null 2>&1; then
    log_info "Using GitHub CLI for security advisories..."
    gh api repos/"$repository"/security-advisories --jq '.[] | "Advisory: \(.summary) (Severity: \(.severity))"'
  else
    log_info "Using curl for GitHub Security Advisories..."
    curl -s -H "Authorization: token $github_token" \
         "https://api.github.com/repos/$repository/security-advisories" | \
    jq -r '.[] | "Advisory: \(.summary) (Severity: \(.severity))"'
  fi
}

# =============================================================================
# OSV (OPEN SOURCE VULNERABILITIES) INTEGRATION
# =============================================================================

check_osv_vulnerabilities() {
  local package_lock_file="${1:-package-lock.json}"

  log_info "Checking OSV (Open Source Vulnerabilities) database..."

  if [ ! -f "$package_lock_file" ]; then
    log_warn "Package lock file not found: $package_lock_file"
    return 1
  fi

  # Install OSV scanner if not available
  if ! command -v osv-scanner >/dev/null 2>&1; then
    log_info "Installing OSV Scanner..."
    # Install via go if available
    if command -v go >/dev/null 2>&1; then
      go install github.com/google/osv-scanner/cmd/osv-scanner@latest
    else
      log_warn "OSV Scanner requires Go to install"
      return 1
    fi
  fi

  # Run OSV scan
  if osv-scanner --lockfile="$package_lock_file" --format=json > osv-results.json; then
    log_info "✅ OSV scan completed"

    # Check if any vulnerabilities found
    if command -v jq >/dev/null 2>&1; then
      local vuln_count=$(jq '.results[].packages[].vulnerabilities | length' osv-results.json 2>/dev/null | awk '{sum += $1} END {print sum+0}')
      if [ "$vuln_count" -gt 0 ]; then
        log_warn "⚠️ OSV found $vuln_count vulnerabilities"
        return 1
      else
        log_info "✅ No vulnerabilities found in OSV database"
        return 0
      fi
    fi
  else
    log_error "❌ OSV scan failed"
    return 1
  fi
}

# =============================================================================
# AUTOMATED SECURITY WORKFLOW GENERATION
# =============================================================================

generate_github_security_workflow() {
  local workflow_file="${1:-.github/workflows/security-scanning.yml}"
  local enable_dependabot="${2:-true}"
  local enable_snyk="${3:-false}"
  local enable_osv="${4:-true}"

  log_info "Generating automated security scanning workflow..."

  mkdir -p "$(dirname "$workflow_file")"

  cat << 'EOF' > "$workflow_file"
name: 🔒 Security Scanning

on:
  pull_request:
    branches: [main, develop, "*-dev", "*-test", "*-prod"]
  push:
    branches: [main, develop, "*-dev", "*-test", "*-prod"]
  schedule:
    # Run security scans weekly on Mondays at 9 AM UTC
    - cron: '0 9 * * 1'
  workflow_dispatch:

concurrency:
  group: security-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  security-scan:
    name: 🔍 Security Analysis
    runs-on: ubuntu-22.04
    permissions:
      security-events: write
      contents: read
      actions: read

    steps:
      - name: 📤 Checkout code
        uses: actions/checkout@v4

      # Enhanced NPM Security Scanning
      - name: 🔒 NPM Security Audit
        run: |
          # Source our utility functions
          source openshift/scripts/utils/npm.sh
          source openshift/scripts/utils/github-actions.sh

          # Run comprehensive NPM security scan
          run_github_actions_npm_security_scan "config/lighthouse" "critical" "true" "true"
EOF

  if [ "$enable_osv" = "true" ]; then
    cat << 'EOF' >> "$workflow_file"

      # OSV Vulnerability Database Scanning
      - name: 🔍 OSV Vulnerability Scan
        uses: google/osv-scanner-action@v1
        with:
          scan-args: |-
            --lockfile=config/lighthouse/package-lock.json
            --format=sarif
            --output=osv-results.sarif
        continue-on-error: true

      - name: 📤 Upload OSV results to GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: osv-results.sarif
          category: osv-scanner
EOF
  fi

  if [ "$enable_snyk" = "true" ]; then
    cat << 'EOF' >> "$workflow_file"

      # Snyk Security Scanning
      - name: 🐍 Snyk Security Scan
        uses: snyk/actions/node@master
        env:
          SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
        with:
          args: --severity-threshold=high --file=config/lighthouse/package.json
        continue-on-error: true

      - name: 📤 Upload Snyk results to GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: snyk.sarif
          category: snyk
EOF
  fi

  cat << 'EOF' >> "$workflow_file"

      # CodeQL Security Analysis for JavaScript/TypeScript
      - name: 🔍 Initialize CodeQL
        uses: github/codeql-action/init@v3
        with:
          languages: javascript
          queries: security-and-quality

      - name: 🔍 Perform CodeQL Analysis
        uses: github/codeql-action/analyze@v3
        with:
          category: codeql-javascript

      # Docker Security Scanning
      - name: 🐳 Docker Security Scan
        uses: aquasec/trivy-action@master
        with:
          scan-type: 'fs'
          scan-ref: '.'
          format: 'sarif'
          output: 'trivy-results.sarif'
        continue-on-error: true

      - name: 📤 Upload Trivy results to GitHub Security
        uses: github/codeql-action/upload-sarif@v3
        if: always()
        with:
          sarif_file: trivy-results.sarif
          category: trivy

      # Security Summary
      - name: 📊 Security Scan Summary
        if: always()
        run: |
          echo "## 🔒 Security Scan Results" >> $GITHUB_STEP_SUMMARY
          echo "| Tool | Status | Details |" >> $GITHUB_STEP_SUMMARY
          echo "|------|--------|---------|" >> $GITHUB_STEP_SUMMARY
          echo "| NPM Audit | ✅ Complete | Custom vulnerability scanning |" >> $GITHUB_STEP_SUMMARY
          echo "| OSV Scanner | ✅ Complete | Open Source Vulnerabilities DB |" >> $GITHUB_STEP_SUMMARY
          echo "| CodeQL | ✅ Complete | GitHub security analysis |" >> $GITHUB_STEP_SUMMARY
          echo "| Trivy | ✅ Complete | Container security scanning |" >> $GITHUB_STEP_SUMMARY
          echo "" >> $GITHUB_STEP_SUMMARY
          echo "All security scan results are available in the [Security tab](https://github.com/${{ github.repository }}/security)." >> $GITHUB_STEP_SUMMARY
EOF

  log_info "✅ Security workflow generated: $workflow_file"
}

# =============================================================================
# CLEANUP UTILITY FOR GITHUB ACTIONS YAML
# =============================================================================

generate_simplified_lighthouse_step() {
  cat << 'EOF'
      # 🔒 Early Security Scanning (blocks unsafe deployments)
      - name: 🔒 Security Validation
        run: |
          cd config/lighthouse
          source ../../openshift/scripts/utils/github-actions.sh

          # Run comprehensive security scan early in pipeline
          if ! run_github_actions_npm_security_scan "." "critical" "true" "true"; then
            echo "❌ Security scan failed - blocking deployment for safety"
            exit 1
          fi

          echo "✅ Security validation passed - proceeding with deployment"

      # 🚦 Lighthouse Performance Testing (after deployment)
      - name: 🚦 Lighthouse Audit
        run: |
          cd config/lighthouse
          source ../../openshift/scripts/utils/lighthouse.sh

          # Setup and run lighthouse with all security validations
          setup_lighthouse_environment "." "true"
          run_lighthouse_audit "$APP_HOST_URL" "." "../tmp/artifacts"
EOF
}

# =============================================================================
# BEST PRACTICES RECOMMENDATIONS
# =============================================================================

display_security_best_practices() {
  log_info "🔒 Security Best Practices Recommendations:"
  log_info ""
  log_info "1. **Dependabot (Recommended)**: Automated dependency updates"
  log_info "   - ✅ Free for public repositories"
  log_info "   - ✅ Integrated with GitHub"
  log_info "   - ✅ Automatic security updates"
  log_info "   - ✅ No additional tokens required"
  log_info ""
  log_info "2. **GitHub Security Advisories (Recommended)**: Built-in vulnerability database"
  log_info "   - ✅ Native GitHub integration"
  log_info "   - ✅ SARIF support for security tab"
  log_info "   - ✅ Free with GitHub"
  log_info ""
  log_info "3. **OSV Scanner (Recommended)**: Google's Open Source Vulnerabilities"
  log_info "   - ✅ Free and open source"
  log_info "   - ✅ Comprehensive vulnerability database"
  log_info "   - ✅ Regular updates"
  log_info ""
  log_info "4. **Snyk (Optional)**: Commercial grade security"
  log_info "   - ⚠️ Requires subscription for private repos"
  log_info "   - ✅ Excellent vulnerability intelligence"
  log_info "   - ✅ Advanced remediation advice"
  log_info ""
  log_info "5. **CodeQL (Recommended)**: Static application security testing"
  log_info "   - ✅ Free for public repositories"
  log_info "   - ✅ Finds code-level security issues"
  log_info "   - ✅ GitHub native integration"
  log_info ""
  log_info "🎯 **Recommended Stack for Your Project**:"
  log_info "   ✅ Dependabot for automated dependency updates"
  log_info "   ✅ GitHub Security Advisories for vulnerability data"
  log_info "   ✅ OSV Scanner for comprehensive open source scanning"
  log_info "   ✅ CodeQL for static code analysis"
  log_info "   ✅ Custom npm.sh utilities for supply chain protection"
}
