#!/bin/bash

# Comprehensive Security Utilities Module
# Multi-ecosystem vulnerability scanning with automation and minimal maintenance
# Covers: Docker, PHP/Composer, System packages, Git dependencies, Container images

# Get the directory where this script is located (local to avoid conflicts)
_SECURITY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the core OpenShift utilities for logging functions
if [[ -f "$_SECURITY_SCRIPT_DIR/openshift.sh" ]]; then
  source "$_SECURITY_SCRIPT_DIR/openshift.sh"
else
  # Fallback: Define minimal logging functions if openshift.sh not found
  log_info() { echo "ℹ️  $*"; }
  log_warn() { echo "⚠️  $*"; }
  log_error() { echo "❌ $*"; }
  log_debug() { echo "🔍 Debug: $*"; }
  log_success() { echo "✅ $*"; }
fi

# =============================================================================
# CONFIGURATION & CONSTANTS
# =============================================================================

# Security scan levels
readonly SCAN_LEVEL_LOW="low"
readonly SCAN_LEVEL_MODERATE="moderate"
readonly SCAN_LEVEL_HIGH="high"
readonly SCAN_LEVEL_CRITICAL="critical"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_WARNING=1
readonly EXIT_CRITICAL=2

# Default configurations
readonly DEFAULT_SCAN_LEVEL="$SCAN_LEVEL_MODERATE"
readonly DEFAULT_ABORT_ON="CRITICAL"
readonly DEFAULT_CACHE_DIR="/tmp/security-cache"

# =============================================================================
# VULNERABILITY EXCEPTION HANDLING
# =============================================================================

load_vulnerability_exceptions() {
  local exceptions_file="$PROJECT_ROOT/.security/vulnerability-exceptions.json"

  if [ -f "$exceptions_file" ]; then
    VULNERABILITY_EXCEPTIONS=$(cat "$exceptions_file")
    log_debug "Loaded vulnerability exceptions from $exceptions_file"
  else
    VULNERABILITY_EXCEPTIONS="{\"exceptions\":[]}"
    log_debug "No vulnerability exceptions file found"
  fi
}

# Check if a vulnerability is excepted (in exception list)
# Usage: is_vulnerability_excepted <cve_id> <package_name>
# Returns: 0 if excepted, 1 if not
is_vulnerability_excepted() {
  local cve_id="$1"
  local package="$2"

  if [ -z "$VULNERABILITY_EXCEPTIONS" ]; then
    load_vulnerability_exceptions
  fi

  # Check if CVE is in exceptions list
  local is_excepted=$(echo "$VULNERABILITY_EXCEPTIONS" | jq -r \
    --arg cve "$cve_id" \
    --arg pkg "$package" \
    '.exceptions[] | select(.cve == $cve and .package == $pkg) | .status' 2>/dev/null || echo "")

  if [ -n "$is_excepted" ]; then
    log_debug "CVE $cve_id in $package is excepted: $is_excepted"
    return 0
  fi

  return 1
}

get_exception_reason() {
  local cve_id="$1"
  local package="$2"

  if [ -z "$VULNERABILITY_EXCEPTIONS" ]; then
    load_vulnerability_exceptions
  fi

  echo "$VULNERABILITY_EXCEPTIONS" | jq -r \
    --arg cve "$cve_id" \
    --arg pkg "$package" \
    '.exceptions[] | select(.cve == $cve and .package == $pkg) | .reason' 2>/dev/null || echo ""
}

# =============================================================================
# DETAILED VULNERABILITY REPORTING
# =============================================================================

generate_detailed_vulnerability_report() {
  local scan_results_file="$1"
  local report_type="$2"  # "docker", "composer", "system"
  local output_file="$3"

  log_info "Generating detailed vulnerability report: $output_file"

  # Load exceptions
  load_vulnerability_exceptions

  # Initialize report
  cat > "$output_file" << 'EOF'
# 🔍 Detailed Vulnerability Report

**Report Type:** %REPORT_TYPE%
**Generated:** %TIMESTAMP%

---

## 📋 Vulnerability Details

| CVE ID | Package | Version | Severity | CVSS | Status | Description |
|--------|---------|---------|----------|------|--------|-------------|
EOF

  # Replace placeholders
  sed -i "s/%REPORT_TYPE%/$report_type/g" "$output_file" 2>/dev/null || \
    sed -i '' "s/%REPORT_TYPE%/$report_type/g" "$output_file" 2>/dev/null || true
  sed -i "s/%TIMESTAMP%/$(date -u +"%Y-%m-%d %H:%M:%S UTC")/g" "$output_file" 2>/dev/null || \
    sed -i '' "s/%TIMESTAMP%/$(date -u +"%Y-%m-%d %H:%M:%S UTC")/g" "$output_file" 2>/dev/null || true

  # Parse vulnerabilities based on report type
  case "$report_type" in
    docker)
      # Parse Trivy JSON results
      if [ -f "$scan_results_file" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.Results[]?.Vulnerabilities[]? |
          select(.Severity == "CRITICAL" or .Severity == "HIGH") |
          "| \(.VulnerabilityID // "N/A") | \(.PkgName // "unknown") | \(.InstalledVersion // "unknown") | \(.Severity) | \(.CVSS.nvd.V3Score // .CVSS.redhat.V3Score // "N/A") | \(if .FixedVersion then "Fix: " + .FixedVersion else "No fix" end) | \(.Title // .Description // "No description")[:80] |"' \
          "$scan_results_file" >> "$output_file" 2>/dev/null || true
      fi
      ;;
    composer)
      # Parse Composer audit JSON
      if [ -f "$scan_results_file" ] && command -v jq >/dev/null 2>&1; then
        jq -r '.advisories[]? |
          "| \(.cve // .advisoryId) | \(.packageName) | \(.affectedVersions) | \(.severity // "UNKNOWN") | N/A | \(if .sources then "Advisory" else "Unknown" end) | \(.title // "No description")[:80] |"' \
          "$scan_results_file" >> "$output_file" 2>/dev/null || true
      fi
      ;;
  esac

  # Add exceptions section
  cat >> "$output_file" << 'EOF'

---

## ✅ Excepted Vulnerabilities

These vulnerabilities have been reviewed and documented as exceptions:

| CVE ID | Package | Status | Reason | Approved By |
|--------|---------|--------|--------|-------------|
EOF

  # List all exceptions
  if [ -n "$VULNERABILITY_EXCEPTIONS" ] && command -v jq >/dev/null 2>&1; then
    echo "$VULNERABILITY_EXCEPTIONS" | jq -r '.exceptions[]? |
      "| \(.cve) | \(.package) | \(.status) | \(.reason[:60]) | \(.approvedBy // .verifiedBy // "N/A") |"' \
      >> "$output_file" 2>/dev/null || true
  fi

  # Add legend
  cat >> "$output_file" << 'EOF'

---

## 📖 Status Legend

- **PATCHED_EXTERNALLY**: Patched via TuxCare or similar service
- **COMPATIBILITY_EXCEPTION**: Update breaks compatibility, risk accepted
- **FALSE_POSITIVE**: Scanner error, not actually vulnerable
- **PLANNED_UPGRADE**: Scheduled for next maintenance window
- **NO_FIX_AVAILABLE**: Vendor has not released patch
- **ACCEPTED_RISK**: Low severity, documented risk acceptance

---

## 🔧 Remediation Guide

### For Non-Whitelisted Vulnerabilities

1. **Update Dependencies**
   ```bash
   # Update specific package
   composer update vendor/package

   # Update container base image
   # Edit example.versions.env and update image tag
   ```

2. **Apply External Patches** (TuxCare/CloudLinux)
   - Document patch in `.security/vulnerability-exceptions.json`
   - Include patch source, date, and verification

3. **Request Exception**
   - Create issue with risk assessment
   - Get approval from Security Team
   - Document in `.security/vulnerability-exceptions.json`

### Exception Documentation Template

```json
{
  "cve": "CVE-2024-XXXXX",
  "package": "package-name",
  "version": "1.2.3",
  "severity": "HIGH",
  "status": "PATCHED_EXTERNALLY",
  "reason": "Patched via TuxCare - vulnerability mitigated without version update",
  "patchSource": "TuxCare",
  "patchDate": "2025-11-06",
  "verifiedBy": "Security Team",
  "expiryDate": "2026-11-06",
  "references": ["https://tuxcare.com/...", "Internal: SEC-1234"]
}
```

---

*Generated by security scanning automation*
EOF

  log_success "Detailed vulnerability report generated: $output_file"
}

# =============================================================================
# DOCKER IMAGE SECURITY
# =============================================================================

scan_docker_image_vulnerabilities() {
  local image_name="$1"
  local scan_level="${2:-$DEFAULT_SCAN_LEVEL}"
  local output_var="${3:-DOCKER_SCAN_RESULT}"
  local exit_on="${4:-none}" # Options: "critical", "high", "none"

  log_info "Scanning Docker image vulnerabilities: $image_name"
  log_debug "Scan level: $scan_level"

  # Check for Trivy (primary tool for CI/CD and OpenShift deployments)
  if ! command -v trivy >/dev/null 2>&1; then
    eval "$output_var='TRIVY_NOT_AVAILABLE'"
    log_warn "Trivy not available - container scanning skipped"
    log_debug "Install Trivy for container vulnerability scanning"
    return 0
  fi

  log_debug "Using Trivy for container vulnerability scanning"

  # Run Trivy scan
  local trivy_output="/tmp/trivy-scan-$(date +%s).json"
  if ! trivy image --format json --output "$trivy_output" "$image_name" >/dev/null 2>&1; then
    rm -f "$trivy_output"
    eval "$output_var='SCAN_FAILED'"
    log_warn "Trivy scan failed for $image_name"
    return 0
  fi

  # Parse Trivy results
  local critical_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$trivy_output" 2>/dev/null || echo "0")
  local high_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$trivy_output" 2>/dev/null || echo "0")

  rm -f "$trivy_output"

  # Evaluate results
  if [ "$critical_count" -gt 0 ]; then
    eval "$output_var='CRITICAL'"
    log_error "CRITICAL: $critical_count critical vulnerabilities in $image_name"
    [ "$exit_on" = "critical" ] && return 2
    return 1
  elif [ "$high_count" -gt 0 ]; then
    eval "$output_var='HIGH'"
    log_warn "HIGH: $high_count high-severity vulnerabilities in $image_name"
    [ "$exit_on" != "none" ] && return 1
    return 0
  else
    eval "$output_var='CLEAN'"
    log_info "✅ No critical/high vulnerabilities found in $image_name"
    return 0
  fi
}

# =============================================================================
# PHP COMPOSER SECURITY
# =============================================================================

# =============================================================================
# PHP COMPOSER SECURITY (CONTAINERIZED)
# =============================================================================

scan_containerized_composer_vulnerabilities() {
  local dockerfile="${1:-Moodle.Dockerfile}"
  local container_tag="${2:-moodle:security-scan}"
  local scan_level="${3:-moderate}"
  local output_var="${4:-COMPOSER_SCAN_RESULT}"

  log_info "Scanning PHP Composer vulnerabilities in containerized build"
  log_debug "Dockerfile: $dockerfile, Container: $container_tag"

  # Build container for security scanning
  log_debug "Building container for Composer security scan..."
  if ! docker build -f "$dockerfile" -t "$container_tag" . >/dev/null 2>&1; then
    eval "$output_var='BUILD_FAILED'"
    log_error "Failed to build container for Composer scanning"
    return 1
  fi

  # Run composer audit inside the container
  local audit_output
  audit_output=$(docker run --rm "$container_tag" bash -c "
    cd /app/public 2>/dev/null || cd /var/www/html 2>/dev/null || cd /app
    if [ -f composer.lock ]; then
      composer audit --format=json 2>/dev/null || echo '{\"advisories\":[]}'
    else
      echo '{\"advisories\":[],\"error\":\"no_composer_lock\"}'
    fi
  " 2>/dev/null)

  # Cleanup container
  docker rmi "$container_tag" >/dev/null 2>&1 || true

  # Parse results
  if [ -n "$audit_output" ] && command -v jq >/dev/null 2>&1; then
    local vuln_count=$(echo "$audit_output" | jq '.advisories | length' 2>/dev/null || echo "0")
    local critical_count=$(echo "$audit_output" | jq '[.advisories[] | select(.severity=="critical")] | length' 2>/dev/null || echo "0")
    local high_count=$(echo "$audit_output" | jq '[.advisories[] | select(.severity=="high")] | length' 2>/dev/null || echo "0")

    if echo "$audit_output" | jq -e '.error=="no_composer_lock"' >/dev/null 2>&1; then
      eval "$output_var='NO_COMPOSER_LOCK'"
      log_debug "No composer.lock found in container - dependencies installed via Dockerfile"
      return 0
    elif [ "$critical_count" -gt 0 ]; then
      eval "$output_var='CRITICAL'"
      log_error "CRITICAL: $critical_count critical PHP vulnerabilities in container"
      return 2
    elif [ "$high_count" -gt 0 ]; then
      eval "$output_var='HIGH'"
      log_warn "HIGH: $high_count high-severity PHP vulnerabilities in container"
      return 1
    elif [ "$vuln_count" -gt 0 ]; then
      eval "$output_var='MODERATE'"
      log_info "MODERATE: $vuln_count moderate PHP vulnerabilities in container"
      return 0
    else
      eval "$output_var='CLEAN'"
      log_info "No PHP security vulnerabilities found in container"
      return 0
    fi
  else
    eval "$output_var='SCAN_FAILED'"
    log_warn "Could not parse Composer audit results"
    return 0
  fi
}

# =============================================================================
# SYSTEM PACKAGE SECURITY
# =============================================================================

scan_system_package_vulnerabilities() {
  local dockerfile="${1:-Moodle.Dockerfile}"
  local container_tag="${2:-moodle:security-scan-packages}"
  local scan_level="${3:-$DEFAULT_SCAN_LEVEL}"
  local output_var="${4:-SYSTEM_SCAN_RESULT}"

  log_info "Scanning system package vulnerabilities in container"
  log_debug "Dockerfile: $dockerfile, Container: $container_tag"

  # Build container for security scanning (reuse if already built)
  if ! docker image inspect "$container_tag" >/dev/null 2>&1; then
    log_debug "Building container for system package scan..."
    if ! docker build -f "$dockerfile" -t "$container_tag" . >/dev/null 2>&1; then
      eval "$output_var='BUILD_FAILED'"
      log_error "Failed to build container for system package scanning"
      return 1
    fi
  fi

  # Run package vulnerability check inside the container
  local scan_output
  scan_output=$(docker run --rm "$container_tag" bash -c '
    if command -v apt >/dev/null 2>&1; then
      apt-get update >/dev/null 2>&1

      # Get security updates with details
      security_updates=$(apt list --upgradable 2>/dev/null | grep -i security || echo "")
      security_count=$(echo "$security_updates" | grep -v "^$" | wc -l)

      if [ "$security_count" -gt 0 ]; then
        echo "SECURITY_UPDATES_FOUND:$security_count"
        echo "$security_updates" | while read -r line; do
          if [ -n "$line" ]; then
            pkg_name=$(echo "$line" | cut -d "/" -f 1)
            version_info=$(echo "$line" | grep -oP "\[.*?\]" | tr -d "[]")
            echo "UPDATE:$pkg_name:$version_info"
          fi
        done
      else
        echo "NO_UPDATES"
      fi
    elif command -v yum >/dev/null 2>&1; then
      security_updates=$(yum --security check-update 2>/dev/null | grep -i "needed for security" || echo "")
      if [ -n "$security_updates" ]; then
        echo "SECURITY_UPDATES_FOUND"
        echo "$security_updates"
      else
        echo "NO_UPDATES"
      fi
    else
      echo "NO_PACKAGE_MANAGER"
    fi
  ' 2>/dev/null)

  # Debug: Show raw scan output when DEBUG_LEVEL is set
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    log_debug "Raw system package scan output:"
    log_debug "$scan_output"
  fi

  # Cleanup container (optional - keep for speed)
  # docker rmi "$container_tag" >/dev/null 2>&1 || true

  # Parse results
  if [ -n "$scan_output" ]; then
    if echo "$scan_output" | grep -q "^NO_UPDATES"; then
      eval "$output_var='CLEAN'"
      log_info "✅ No security updates needed for container packages"
      return 0
    elif echo "$scan_output" | grep -q "^NO_PACKAGE_MANAGER"; then
      eval "$output_var='NO_PACKAGE_MANAGER'"
      log_debug "No supported package manager found in container"
      return 0
    elif echo "$scan_output" | grep -q "^SECURITY_UPDATES_FOUND"; then
      local update_count=$(echo "$scan_output" | grep "^SECURITY_UPDATES_FOUND" | cut -d ":" -f 2)

      eval "$output_var='UPDATES_NEEDED'"

      if [ "$update_count" -gt 10 ]; then
        log_error "CRITICAL: $update_count security updates needed in container"
      else
        log_warn "WARNING: $update_count security updates needed in container"
      fi

      # List the specific packages needing updates
      local update_details=$(echo "$scan_output" | grep "^UPDATE:")
      if [ -n "$update_details" ]; then
        log_info "📦 Packages requiring security updates:"
        echo "$update_details" | head -10 | while IFS=: read -r _ pkg_name version_info; do
          if [ -n "$pkg_name" ]; then
            log_info "   • $pkg_name: $version_info"
          fi
        done

        local total_shown=$(echo "$update_details" | wc -l)
        if [ "$total_shown" -gt 10 ]; then
          log_info "   ... and $((total_shown - 10)) more packages"
        fi
      else
        # Fallback: Show the raw security updates if UPDATE: lines not found
        log_warn "Package details not parsed. Showing raw output:"
        echo "$scan_output" | grep -v "^SECURITY_UPDATES_FOUND" | grep -v "^NO_UPDATES" | grep -v "^NO_PACKAGE_MANAGER" | head -10
      fi

      if [ "$update_count" -gt 10 ]; then
        return 2  # Critical
      else
        return 1  # Warning
      fi
    fi
  else
    eval "$output_var='SCAN_FAILED'"
    log_warn "Could not scan container packages"
    return 0
  fi
}

# =============================================================================
# GIT DEPENDENCY SECURITY
# =============================================================================

# Extract repository details from Dockerfile ARG variables
extract_dockerfile_repos() {
  local dockerfile="$1"
  local repos_json="[]"

  # Extract ARG lines that define repository URLs and versions
  while IFS= read -r line; do
    if [[ "$line" =~ ^ARG[[:space:]]+([A-Z_]+)=\"?([^\"]+)\"?$ ]]; then
      local var_name="${BASH_REMATCH[1]}"
      local var_value="${BASH_REMATCH[2]}"

      # Check if this is a URL variable
      if [[ "$var_name" =~ _URL$ ]]; then
        local repo_name="${var_name%_URL}"
        local branch_var="${repo_name}_BRANCH_VERSION"

        # Extract the corresponding branch/version
        local branch_version=$(grep "^ARG ${branch_var}=" "$dockerfile" | sed -E 's/^ARG [^=]+=["'"'"']?([^"'"'"']*)["'"'"']?$/\1/')

        # Parse GitHub URL to extract owner/repo
        if [[ "$var_value" =~ github\.com/([^/]+)/([^/]+)/?$ ]]; then
          local owner="${BASH_REMATCH[1]}"
          local repo="${BASH_REMATCH[2]}"

          # Add to JSON array (use here-document for clarity)
          repos_json=$(jq --argjson arr "$repos_json" \
                          --arg name "$repo_name" \
                          --arg url "$var_value" \
                          --arg owner "$owner" \
                          --arg repo "$repo" \
                          --arg version "$branch_version" \
                          '($arr + [{
                            name: $name,
                            url: $url,
                            owner: $owner,
                            repo: $repo,
                            version: $version
                          }])' <<< "{}")
        fi
      fi
    fi
  done < "$dockerfile"

  echo "$repos_json"
}

# Check Moodle version for known security advisories
check_moodle_security_advisories() {
  local moodle_version="$1"  # e.g., "MOODLE_401_STABLE"
  local output_var="${2:-MOODLE_SECURITY_RESULT}"

  log_info "Checking Moodle security advisories for version: $moodle_version"

  # Extract numeric version (e.g., MOODLE_401_STABLE -> 4.01 or 4.1)
  local version_number=""
  if [[ "$moodle_version" =~ MOODLE_([0-9])([0-9]{2})_STABLE ]]; then
    local major="${BASH_REMATCH[1]}"
    local minor="${BASH_REMATCH[2]}"
    version_number="${major}.${minor#0}"  # Remove leading zero from minor
  fi

  if [ -z "$version_number" ]; then
    eval "$output_var='UNKNOWN_VERSION'"
    log_debug "Could not parse Moodle version: $moodle_version"
    return 0
  fi

  log_debug "Parsed Moodle version: $version_number"

  # Try to fetch Moodle security advisories from official source
  local advisories_url="https://moodle.org/security/index.php?o=json"
  local advisories_json=$(curl -s --max-time 10 "$advisories_url" 2>/dev/null)

  if [ -n "$advisories_json" ] && command -v jq >/dev/null 2>&1; then
    # Check if there are any advisories affecting this version
    local affected_count=$(echo "$advisories_json" | jq --arg ver "$version_number" '
      [.[] | select(.affects | contains($ver))] | length
    ' 2>/dev/null || echo "0")

    if [ "$affected_count" -gt 0 ]; then
      eval "$output_var='ADVISORIES_FOUND'"
      log_warn "Found $affected_count security advisories affecting Moodle $version_number"
      log_warn "Review: https://moodle.org/security/"
      return 1
    else
      eval "$output_var='NO_ADVISORIES'"
      log_info "✅ No known security advisories for Moodle $version_number"
      return 0
    fi
  else
    eval "$output_var='CHECK_FAILED'"
    log_debug "Could not fetch Moodle security advisories (network or parsing issue)"
    return 0
  fi
}

# Check GitHub repository for security advisories
check_github_security_advisories() {
  local owner="$1"
  local repo="$2"
  local version="$3"
  local output_var="${4:-GITHUB_ADVISORY_RESULT}"

  log_debug "Checking GitHub security advisories: $owner/$repo @ $version"

  # Use GraphQL API for better public access to security advisories
  # This endpoint works without authentication for public repositories
  local graphql_url="https://api.github.com/graphql"
  local query='{"query":"{ repository(owner: \"'$owner'\", name: \"'$repo'\") { vulnerabilityAlerts(first: 100, states: OPEN) { nodes { createdAt securityVulnerability { severity package { name } advisory { summary publishedAt } } } } } }"}'

  # Try GraphQL first (more reliable for public access)
  local advisories_json=$(curl -s --max-time 10 \
    -H "Content-Type: application/json" \
    -H "Accept: application/vnd.github+json" \
    -X POST \
    -d "$query" \
    "$graphql_url" 2>/dev/null)

  if [ -n "$advisories_json" ] && command -v jq >/dev/null 2>&1; then
    # Check for GraphQL errors (usually means no access or repo doesn't exist)
    local has_errors=$(echo "$advisories_json" | jq -r '.errors // [] | length' 2>/dev/null || echo "0")

    if [ "$has_errors" -gt 0 ]; then
      # GraphQL failed, try REST API as fallback
      local rest_url="https://api.github.com/repos/$owner/$repo/security-advisories"
      advisories_json=$(curl -s --max-time 10 \
        -H "Accept: application/vnd.github+json" \
        "$rest_url" 2>/dev/null)

      # Check if REST API returned valid JSON array
      if echo "$advisories_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
        # Filter for published advisories only
        local advisory_count=$(echo "$advisories_json" | jq '[.[] | select(.state == "published")] | length' 2>/dev/null || echo "0")

        if [ "$advisory_count" -gt 0 ]; then
          eval "$output_var='ADVISORIES_FOUND'"
          log_warn "Found $advisory_count published security advisories for $owner/$repo"
          log_warn "Review: https://github.com/$owner/$repo/security/advisories"
          return 1
        fi
      fi

      # If we get here, no advisories found or API access denied
      eval "$output_var='NO_ADVISORIES'"
      log_debug "No security advisories found for $owner/$repo (or no public access)"
      return 0
    fi

    # Process GraphQL response
    local alert_count=$(echo "$advisories_json" | jq -r '.data.repository.vulnerabilityAlerts.nodes // [] | length' 2>/dev/null || echo "0")

    if [ "$alert_count" -gt 0 ]; then
      eval "$output_var='ADVISORIES_FOUND'"
      log_warn "Found $alert_count open vulnerability alerts for $owner/$repo"
      log_warn "Review: https://github.com/$owner/$repo/security/advisories"
      return 1
    else
      eval "$output_var='NO_ADVISORIES'"
      log_debug "No security advisories found for $owner/$repo"
      return 0
    fi
  else
    eval "$output_var='CHECK_FAILED'"
    log_debug "Could not fetch GitHub security advisories for $owner/$repo (API unavailable)"
    return 0
  fi
}

# Check if SSL verification is disabled (security risk)
check_git_ssl_verification() {
  local dockerfile="$1"
  local output_var="${2:-SSL_VERIFICATION_RESULT}"

  if grep -q "GIT_SSL_NO_VERIFY=1" "$dockerfile" 2>/dev/null; then
    eval "$output_var='SSL_DISABLED'"
    log_warn "WARNING: SSL verification disabled (GIT_SSL_NO_VERIFY=1) in $dockerfile"
    log_warn "This may be acceptable for development but is a security risk in production"
    log_warn "Recommendation: Remove GIT_SSL_NO_VERIFY or set to 0 for production builds"
    return 1  # Changed from 2 (critical) to 1 (warning)
  else
    eval "$output_var='SSL_ENABLED'"
    log_debug "SSL verification is enabled (GIT_SSL_NO_VERIFY not set to 1)"
    return 0
  fi
}

scan_git_dependencies() {
  local project_dir="${1:-.}"
  local output_var="${2:-GIT_SCAN_RESULT}"

  log_info "Scanning Git dependencies for security issues"

  # Save original directory to return to it later
  local original_dir="$(pwd)"

  cd "$project_dir" || return 1

  # Look for Git submodules and external repositories in Dockerfiles
  local security_issues=0
  local total_repos=0
  local advisories_found=0

  # Check .gitmodules
  if [ -f ".gitmodules" ]; then
    log_debug "Checking Git submodules"
    total_repos=$((total_repos + $(grep -c "url = " .gitmodules 2>/dev/null || echo "0")))
  fi

  # Check Dockerfiles for git clone commands and security issues
  while IFS= read -r dockerfile; do
    log_debug "Analyzing Dockerfile: $dockerfile"

    # Count git clones
  local git_clones
  git_clones=$(grep -c "git clone" "$dockerfile" 2>/dev/null | tr -d '\n' | tr -d -c '0-9')
  git_clones="${git_clones:-0}"
  total_repos=$((total_repos + git_clones))

    # Check for SSL verification disabled
    local ssl_result=""
    check_git_ssl_verification "$dockerfile" "ssl_result"
    local ssl_exit=$?
    if [ $ssl_exit -eq 2 ]; then
      security_issues=$((security_issues + 1))
    elif [ $ssl_exit -eq 1 ]; then
      # SSL disabled is a warning, not critical
      log_debug "SSL verification disabled - counted as warning"
    fi

    # Check for insecure HTTP git clone patterns
    if grep -q "git clone.*http://" "$dockerfile" 2>/dev/null; then
      log_warn "Insecure HTTP git clone found in $dockerfile"
      security_issues=$((security_issues + 1))
    fi

    # Check for git clone without depth (performance concern, not security)
    if grep -q "git clone" "$dockerfile" 2>/dev/null && ! grep -q "depth=" "$dockerfile" 2>/dev/null; then
      log_debug "Git clone without --depth found in $dockerfile (performance concern)"
    fi

    # Extract and check repository versions for security advisories
    if command -v jq >/dev/null 2>&1; then
      local repos_json=$(extract_dockerfile_repos "$dockerfile")
      local repo_count=$(echo "$repos_json" | jq '. | length')

      if [ "$repo_count" -gt 0 ]; then
        log_info "📦 Found $repo_count repositories defined in $dockerfile"

        # Check each repository for security advisories
        # Use different file descriptor to avoid interfering with outer loop
        while IFS= read -r -u 3 repo; do
          local name=$(echo "$repo" | jq -r '.name')
          local owner=$(echo "$repo" | jq -r '.owner')
          local repo_name=$(echo "$repo" | jq -r '.repo')
          local version=$(echo "$repo" | jq -r '.version')
          local url=$(echo "$repo" | jq -r '.url')

          log_debug "Checking: $name ($owner/$repo_name @ $version)"

          # Special handling for Moodle core
          if [[ "$name" == "MOODLE" ]]; then
            local moodle_result=""
            check_moodle_security_advisories "$version" "moodle_result"
            if [[ "$moodle_result" == "ADVISORIES_FOUND" ]]; then
              advisories_found=$((advisories_found + 1))
            fi
          fi

          # Check GitHub security advisories for all repos
          local github_result=""
          check_github_security_advisories "$owner" "$repo_name" "$version" "github_result"
          if [[ "$github_result" == "ADVISORIES_FOUND" ]]; then
            advisories_found=$((advisories_found + 1))
          fi
        done 3< <(echo "$repos_json" | jq -c '.[]')
      fi
    fi
  done < <(find . -name "*.Dockerfile" -o -name "Dockerfile*")

  # Return to original directory before exit
  cd "$original_dir" || log_warn "Failed to return to original directory: $original_dir"

  # Determine overall result
  if [ "$security_issues" -gt 0 ]; then
    eval "$output_var='SECURITY_ISSUES'"
    log_error "Git dependency security issues found: $security_issues critical issues"
    return 2
  elif [ "$advisories_found" -gt 0 ]; then
    eval "$output_var='ADVISORIES_FOUND'"
    log_warn "Security advisories found for $advisories_found repositories - review recommended"
    return 1
  elif [ "$total_repos" -gt 0 ]; then
    eval "$output_var='DEPENDENCIES_FOUND'"
    log_info "Git dependencies found: $total_repos (no security issues detected)"
    return 0
  else
    eval "$output_var='NO_GIT_DEPS'"
    log_debug "No Git dependencies found"
    return 0
  fi
}

# =============================================================================
# COMPREHENSIVE SECURITY SCAN
# =============================================================================

comprehensive_security_scan() {
  local project_dir="${1:-.}"
  local scan_level="${2:-$DEFAULT_SCAN_LEVEL}"
  local abort_on="${3:-$DEFAULT_ABORT_ON}"
  local skip_containerized="${4:-true}"  # Skip container builds by default (handled post-build)

  log_info "Running comprehensive security scan..."

  if [ "$skip_containerized" = "true" ]; then
    log_info "Strategy: Git Dependencies + Base Images (checkEnv) + Post-Build Scanning (build jobs)"
    log_trace "Skipping containerized scans to avoid duplicate builds"
  else
    log_info "Automated tools: Composer Audit + Trivy + System Updates + Git Analysis"
  fi

  log_trace "Project: $project_dir, Level: $scan_level, Abort on: $abort_on"

  # Save original directory to return to it later
  local original_dir="$(pwd)"

  cd "$project_dir" || return 1

  # Check for cached scan results
  local cache_valid=false
  local cached_summary="tmp/comprehensive-security-summary.json"

  if [ -f "$cached_summary" ]; then
    local cache_age_seconds=$(( $(date +%s) - $(stat -c %Y "$cached_summary" 2>/dev/null || stat -f %m "$cached_summary" 2>/dev/null || echo 0) ))
    local cache_max_age=86400  # 24 hours

    if [ $cache_age_seconds -lt $cache_max_age ]; then
      log_info "✓ Found valid cached security scan (${cache_age_seconds}s old, max ${cache_max_age}s)"
      log_info "  Using cached results to speed up build"
      cache_valid=true

      # Extract status from cached results
      local cached_exit=$(jq -r '.exit_code // 0' "$cached_summary" 2>/dev/null || echo 0)

      cd "$original_dir"
      return $cached_exit
    else
      log_trace "Cached results expired (${cache_age_seconds}s > ${cache_max_age}s), running fresh scan"
    fi
  else
    log_trace "No cached security results found, running full scan"
  fi

  # Initialize result tracking
  local overall_status="CLEAN"
  local critical_issues=0
  local high_issues=0
  local warnings=0

  # Track individual scan results
  local composer_result="SKIPPED"
  local system_result="SKIPPED"
  local git_result=""

  # Conditional scanning based on skip_containerized flag
  if [ "$skip_containerized" = "false" ]; then
    # 1. PHP Composer Security Scan (Containerized) - Only if not skipping
    log_info "🔍 Phase 1: PHP Composer Security (Containerized Build)"
    scan_containerized_composer_vulnerabilities "Moodle.Dockerfile" "moodle:security-scan-$$" "$scan_level" "composer_result"
    local composer_exit=$?

    if [ $composer_exit -eq 2 ]; then
      critical_issues=$((critical_issues + 1))
      overall_status="CRITICAL"
    elif [ $composer_exit -eq 1 ]; then
      high_issues=$((high_issues + 1))
      [ "$overall_status" = "CLEAN" ] && overall_status="HIGH"
    fi

    # 2. System Package Security Scan
    log_info "🔍 Phase 2: System Package Security"
    scan_system_package_vulnerabilities "Moodle.Dockerfile" "moodle:security-scan-$$" "$scan_level" "system_result"
    local system_exit=$?

    if [ $system_exit -eq 2 ]; then
      critical_issues=$((critical_issues + 1))
      overall_status="CRITICAL"
    elif [ $system_exit -eq 1 ]; then
      warnings=$((warnings + 1))
      [ "$overall_status" = "CLEAN" ] && overall_status="WARNINGS"
    fi
  else
    log_trace "Skipping Phases 1-2 (containerized scans) - handled by post-build scanning"
  fi

  # 3. Git Dependencies Security (Always run - no container build needed)
  log_info "🔍 Phase 3: Git Dependencies Security"
  scan_git_dependencies "$project_dir" "git_result"
  local git_exit=$?

  if [ $git_exit -eq 2 ]; then
    critical_issues=$((critical_issues + 1))
    overall_status="CRITICAL"
  elif [ $git_exit -eq 1 ]; then
    warnings=$((warnings + 1))
    [ "$overall_status" = "CLEAN" ] && overall_status="WARNINGS"
  fi

  # Generate comprehensive summary
  log_info "🛡️  Comprehensive Security Scan Summary:"

  if [ "$skip_containerized" = "false" ]; then
    log_info "  PHP Composer: $composer_result"
    log_info "  System Packages: $system_result"
  fi

  log_info "  Git Dependencies: $git_result"
  log_info "  Overall Status: $overall_status"
  log_info "  Critical Issues: $critical_issues"
  log_info "  High/Warning Issues: $((high_issues + warnings))"

  if [ "$skip_containerized" = "true" ]; then
    log_info "  Note: Container security scans run post-build (before push to registry)"
  fi

  log_info "  Automation: Dependabot handles updates automatically"

  # Determine exit code based on graduated abort threshold
  local final_exit_code=0
  local should_abort=false

  case "$abort_on" in
    MEDIUM)
      if [ $critical_issues -gt 0 ] || [ $high_issues -gt 0 ] || [ $warnings -gt 0 ]; then
        should_abort=true
      fi
      ;;
    HIGH)
      if [ $critical_issues -gt 0 ] || [ $high_issues -gt 0 ]; then
        should_abort=true
      fi
      ;;
    CRITICAL)
      if [ $critical_issues -gt 0 ]; then
        should_abort=true
      fi
      ;;
    NEVER|*)
      ;;
  esac

  if [ "$should_abort" = "true" ]; then
    final_exit_code=2
  elif [ $critical_issues -gt 0 ] || [ $high_issues -gt 0 ]; then
    final_exit_code=1
  fi

  # Save scan results to cache for future builds
  mkdir -p "$(dirname "$cached_summary")"
  cat > "$cached_summary" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "scan_level": "$scan_level",
  "overall_status": "$overall_status",
  "critical_issues": $critical_issues,
  "high_issues": $high_issues,
  "warnings": $warnings,
  "composer_result": "$composer_result",
  "system_result": "$system_result",
  "git_result": "$git_result",
  "skip_containerized": "$skip_containerized",
  "exit_code": $final_exit_code,
  "cached": true
}
EOF
  log_trace "Cached security scan results for future builds"

  # Return to original directory before exit
  cd "$original_dir" || log_warn "Failed to return to original directory: $original_dir"

  # Determine exit strategy
  if [ $final_exit_code -eq 2 ]; then
    log_error "Build aborted due to critical security issues!"
    log_error "Recommendation: Review security scan results and apply updates"
    return 2
  elif [ $final_exit_code -eq 1 ]; then
    log_warn "Security issues detected - review recommended"
    return 1
  else
    log_info "✅ Security scan passed - no critical issues detected"
    return 0
  fi
}

# =============================================================================
# SECURITY UTILITIES FOR CI/CD
# =============================================================================

setup_security_tools() {
  local install_tools="${1:-false}"

  log_info "Setting up security scanning tools..."

  # Check available tools
  local tools_available=()
  local tools_missing=()

  # Check Trivy (primary tool for CI/CD and OpenShift)
  if command -v trivy >/dev/null 2>&1; then
    tools_available+=("Trivy")
  else
    tools_missing+=("Trivy")
  fi

  # Check Composer
  if composer --version >/dev/null 2>&1; then
    tools_available+=("Composer")
    local composer_version=$(composer --version | grep -oP 'Composer version \K\d+\.\d+')
    if dpkg --compare-versions "$composer_version" ge "2.4"; then
      tools_available+=("Composer Audit")
    else
      tools_missing+=("Composer Audit (requires 2.4+)")
    fi
  else
    tools_missing+=("Composer")
  fi

  log_info "Available tools: ${tools_available[*]}"
  [ ${#tools_missing[@]} -gt 0 ] && log_debug "Missing tools: ${tools_missing[*]}"

  # Install missing tools if requested
  if [ "$install_tools" = "true" ]; then
    log_info "Installing missing security tools..."

    # Install Trivy if missing and we have apt
    if [[ "${tools_missing[*]}" =~ "Trivy" ]] && command -v apt-get >/dev/null 2>&1; then
      log_debug "Installing Trivy..."
      apt-get update >/dev/null 2>&1
      apt-get install -y wget apt-transport-https gnupg lsb-release >/dev/null 2>&1
      wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | apt-key add - >/dev/null 2>&1
      echo "deb https://aquasecurity.github.io/trivy-repo/deb $(lsb_release -sc) main" | tee -a /etc/apt/sources.list.d/trivy.list >/dev/null 2>&1
      apt-get update >/dev/null 2>&1
      apt-get install -y trivy >/dev/null 2>&1
      log_info "✅ Trivy installed"
    fi
  fi

  return 0
}

get_security_recommendations() {
  local project_dir="${1:-.}"

  log_info "🔧 Security Recommendations:"
  log_info "  1. Enable Dependabot for automated updates (✅ Already configured)"
  log_info "  2. Run security scans in CI/CD pipeline (✅ Implemented)"
  log_info "  3. Regular base image updates via Dependabot Docker ecosystem"
  log_info "  4. Use specific image tags instead of 'latest' in Dockerfiles"
  log_info "  5. Use Trivy for container image vulnerability scanning"
  log_info "  6. Keep Composer dependencies updated with 'composer audit'"
  log_info "  7. Review Git dependencies for secure HTTPS URLs"
  log_info "  8. Monitor security advisories for Moodle core and plugins"
  log_info "  9. Check Moodle security announcements: https://moodle.org/security/"
  log_info "  10. Review plugin security via GitHub security advisories"

  # Check current Dockerfile practices
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "FROM.*:latest" >/dev/null 2>&1; then
    log_warn "Found 'latest' tags in Dockerfiles - consider using specific versions"
  fi

  # Check for HTTP git clones
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "git clone.*http://" >/dev/null 2>&1; then
    log_error "Found insecure HTTP git clones - update to HTTPS"
  fi

  # Check for SSL verification disabled
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "GIT_SSL_NO_VERIFY=1" >/dev/null 2>&1; then
    log_error "CRITICAL: SSL verification disabled in Dockerfiles"
  fi

  return 0
}

# Read Docker images from generated manifest (optimization)
scan_docker_images_from_manifest() {
  local manifest="$PROJECT_ROOT/openshift/dependencies/images.yml"

  if [ ! -f "$manifest" ]; then
    log_warn "Docker images manifest not found: $manifest"
    log_warn "Run populate-dependency-manifests.sh first"
    return 0
  fi

  log_info "Reading Docker images from generated manifest"

  # Parse YAML and scan each image (requires yq or Python)
  if command -v yq >/dev/null 2>&1; then
    yq eval '.services[].image' "$manifest" 2>/dev/null | while IFS= read -r image; do
      if [ -n "$image" ] && [ "$image" != "null" ]; then
        scan_docker_image_vulnerabilities "$image"
      fi
    done
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c "
import yaml
with open('$manifest') as f:
    data = yaml.safe_load(f)
    for service in data.get('services', {}).values():
        print(service.get('image', ''))
" | while IFS= read -r image; do
      if [ -n "$image" ]; then
        scan_docker_image_vulnerabilities "$image"
      fi
    done
  else
    log_warn "yq or Python required to parse manifest, falling back to defaults"
    return 1
  fi
}

# Read Git repositories from generated manifest (optimization)
scan_git_repos_from_manifest() {
  local manifest="$PROJECT_ROOT/config/moodle/git-dependencies.json"

  if [ ! -f "$manifest" ]; then
    log_warn "Git dependencies manifest not found: $manifest"
    log_warn "Run populate-dependency-manifests.sh first"
    return 0
  fi

  log_info "Reading Git repositories from generated manifest"

  # Parse JSON and check repos marked for security scanning
  jq -r '.repositories[] | select(.security_scan == true) | "\(.url)|\(.branch)"' "$manifest" | \
  while IFS='|' read -r url branch; do
    if [ -n "$url" ]; then
      # Extract owner/repo from URL
      local repo_path=$(echo "$url" | sed -E 's|https?://github\.com/||' | sed 's|\.git$||')
      local owner=$(echo "$repo_path" | cut -d'/' -f1)
      local repo=$(echo "$repo_path" | cut -d'/' -f2)

      check_github_security_advisories "$owner" "$repo" "$branch"
    fi
  done
}

# Display detailed repository inventory with security information
display_repository_inventory() {
  local project_dir="${1:-.}"

  log_info "📦 Repository Inventory:"

  # Save original directory
  local original_dir="$(pwd)"
  cd "$project_dir" || return 1

  # Find and analyze all Dockerfiles
  while IFS= read -r dockerfile; do
    if command -v jq >/dev/null 2>&1; then
      local repos_json=$(extract_dockerfile_repos "$dockerfile")
      local repo_count=$(echo "$repos_json" | jq '. | length')

      if [ "$repo_count" -gt 0 ]; then
        log_info ""
        log_info "From: $dockerfile"
        log_info "Repositories: $repo_count"
        log_info ""

        echo "$repos_json" | jq -r '.[] | "  • \(.name): \(.url) @ \(.version)"'
      fi
    fi
  done < <(find . -name "*.Dockerfile" -o -name "Dockerfile*")

  cd "$original_dir" || return 1
  return 0
}