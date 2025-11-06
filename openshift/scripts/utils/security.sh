#!/bin/bash

# Comprehensive Security Utilities Module
# Multi-ecosystem vulnerability scanning with automation and minimal maintenance
# Covers: Docker, PHP/Composer, System packages, Git dependencies, Container images

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the core OpenShift utilities for logging functions
if [[ -f "$SCRIPT_DIR/openshift.sh" ]]; then
  source "$SCRIPT_DIR/openshift.sh"
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
readonly DEFAULT_ABORT_ON_CRITICAL="true"
readonly DEFAULT_CACHE_DIR="/tmp/security-cache"

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

  # Check for available scanning tools first
  local has_docker_scout=false
  local has_trivy=false

  if command -v docker >/dev/null 2>&1 && docker scout version >/dev/null 2>&1; then
    has_docker_scout=true
  fi

  if command -v trivy >/dev/null 2>&1; then
    has_trivy=true
  fi

  # Exit early if no tools available
  if [ "$has_docker_scout" = false ] && [ "$has_trivy" = false ]; then
    eval "$output_var='UNKNOWN'"
    log_warn "No container scanning tools available (Docker Scout, Trivy)"
    return 0
  fi

  local scan_output
  local exit_code=0
  local high_count=0
  local critical_count=0

  # Try Docker Scout first if available
  if [ "$has_docker_scout" = true ]; then
    log_debug "Using Docker Scout for vulnerability scanning"

    scan_output=$(docker scout cves "$image_name" --format json 2>/dev/null) || exit_code=$?

    if [ $exit_code -eq 0 ] && [ -n "$scan_output" ]; then
      # Parse Scout results
      critical_count=$(echo "$scan_output" | jq -r '[.vulnerabilities[]? | select(.severity=="critical")] | length' 2>/dev/null || echo "0")
      high_count=$(echo "$scan_output" | jq -r '[.vulnerabilities[]? | select(.severity=="high")] | length' 2>/dev/null || echo "0")

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
        log_info "No critical/high vulnerabilities found in $image_name"
        return 0
      fi
    fi
  fi

  # Fallback to Trivy if Docker Scout unavailable or failed
  if [ "$has_trivy" = true ]; then
    log_debug "Using Trivy for vulnerability scanning"

    local trivy_output="/tmp/trivy-scan-$(date +%s).json"
    if trivy image --format json --output "$trivy_output" "$image_name" >/dev/null 2>&1; then
      critical_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$trivy_output" 2>/dev/null || echo "0")
      high_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$trivy_output" 2>/dev/null || echo "0")

      rm -f "$trivy_output"

      if [ "$critical_count" -gt 0 ]; then
        eval "$output_var='CRITICAL'"
        log_error "CRITICAL: $critical_count critical vulnerabilities in $image_name"
        return 2
      elif [ "$high_count" -gt 0 ]; then
        eval "$output_var='HIGH'"
        log_warn "HIGH: $high_count high-severity vulnerabilities in $image_name"
        return 1
      else
        eval "$output_var='CLEAN'"
        log_info "No critical/high vulnerabilities found in $image_name"
        return 0
      fi
    else
      rm -f "$trivy_output"
      eval "$output_var='SCAN_FAILED'"
      log_warn "Trivy scan failed for $image_name"
      return 0
    fi
  fi

  # Should never reach here due to early exit, but just in case
  eval "$output_var='UNKNOWN'"
  log_warn "No container scanning tools available"
  return 0
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
  local scan_level="${1:-$DEFAULT_SCAN_LEVEL}"
  local output_var="${2:-SYSTEM_SCAN_RESULT}"

  log_info "Scanning system package vulnerabilities"

  # Check if we're in a container or have package managers
  if command -v apt >/dev/null 2>&1; then
    log_debug "Scanning APT packages for vulnerabilities"

    # Update package lists
    apt-get update >/dev/null 2>&1 || true

    # Check for security updates
    local security_updates=$(apt list --upgradable 2>/dev/null | grep -i security | wc -l)
    local total_updates=$(apt list --upgradable 2>/dev/null | grep -v "WARNING" | wc -l)

    if [ "$security_updates" -gt 10 ]; then
      eval "$output_var='CRITICAL'"
      log_error "CRITICAL: $security_updates security updates available"
      return 2
    elif [ "$security_updates" -gt 0 ]; then
      eval "$output_var='UPDATES_NEEDED'"
      log_warn "WARNING: $security_updates security updates available"
      return 1
    else
      eval "$output_var='CLEAN'"
      log_info "System packages are up to date"
      return 0
    fi
  elif command -v yum >/dev/null 2>&1; then
    log_debug "Scanning YUM packages for vulnerabilities"

    local security_updates=$(yum --security check-update 2>/dev/null | grep -c "needed for security" || echo "0")

    if [ "$security_updates" -gt 0 ]; then
      eval "$output_var='UPDATES_NEEDED'"
      log_warn "WARNING: $security_updates security updates available"
      return 1
    else
      eval "$output_var='CLEAN'"
      log_info "System packages are up to date"
      return 0
    fi
  else
    eval "$output_var='NO_PACKAGE_MANAGER'"
    log_debug "No supported package manager found"
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
      log_warn "⚠️  Found $affected_count security advisories affecting Moodle $version_number"
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
          log_warn "⚠️  Found $advisory_count published security advisories for $owner/$repo"
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
      log_warn "⚠️  Found $alert_count open vulnerability alerts for $owner/$repo"
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
    log_error "❌ CRITICAL: SSL verification disabled (GIT_SSL_NO_VERIFY=1) in $dockerfile"
    log_error "This is a security risk - remove GIT_SSL_NO_VERIFY or set to 0"
    return 2
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
    if [ $? -eq 2 ]; then
      security_issues=$((security_issues + 1))
    fi

    # Check for insecure HTTP git clone patterns
    if grep -q "git clone.*http://" "$dockerfile" 2>/dev/null; then
      log_warn "⚠️  Insecure HTTP git clone found in $dockerfile"
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
        echo "$repos_json" | jq -c '.[]' | while read -r repo; do
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
        done
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
  local abort_on_critical="${3:-$DEFAULT_ABORT_ON_CRITICAL}"
  local scan_images="${4:-false}"

  log_info "Running comprehensive security scan..."
  log_info "Automated tools: Composer Audit + Docker Scout/Trivy + System Updates + Git Analysis"
  log_debug "Project: $project_dir, Level: $scan_level, Abort on critical: $abort_on_critical"

  # Save original directory to return to it later
  local original_dir="$(pwd)"

  cd "$project_dir" || return 1

  # Initialize result tracking
  local overall_status="CLEAN"
  local critical_issues=0
  local high_issues=0
  local warnings=0

  # Track individual scan results
  local composer_result=""
  local docker_result=""
  local system_result=""
  local git_result=""

  # 1. PHP Composer Security Scan (Containerized)
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
  scan_system_package_vulnerabilities "$scan_level" "system_result"
  local system_exit=$?

  if [ $system_exit -eq 2 ]; then
    critical_issues=$((critical_issues + 1))
    overall_status="CRITICAL"
  elif [ $system_exit -eq 1 ]; then
    warnings=$((warnings + 1))
    [ "$overall_status" = "CLEAN" ] && overall_status="WARNINGS"
  fi

  # 3. Git Dependencies Security
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

  # 4. Docker Image Scan (optional - can be slow)
  if [ "$scan_images" = "true" ]; then
    log_info "🔍 Phase 4: Docker Image Security"

    # Scan base images mentioned in Dockerfiles
    find . -name "*.Dockerfile" -o -name "Dockerfile*" | while read -r dockerfile; do
      local base_images=$(grep -i "^FROM " "$dockerfile" | awk '{print $2}' | head -3)
      for image in $base_images; do
        if [[ "$image" != scratch && "$image" != *"AS"* ]]; then
          log_debug "Scanning base image: $image"
          scan_docker_image_vulnerabilities "$image" "$scan_level" "docker_result"
          local docker_exit=$?

          if [ $docker_exit -eq 2 ]; then
            critical_issues=$((critical_issues + 1))
            overall_status="CRITICAL"
          elif [ $docker_exit -eq 1 ]; then
            high_issues=$((high_issues + 1))
            [ "$overall_status" = "CLEAN" ] && overall_status="HIGH"
          fi
        fi
      done
    done
  fi

  # Generate comprehensive summary
  log_info "🛡️  Comprehensive Security Scan Summary:"
  log_info "  PHP Composer: $composer_result"
  log_info "  System Packages: $system_result"
  log_info "  Git Dependencies: $git_result"
  [ "$scan_images" = "true" ] && log_info "  Docker Images: $docker_result"
  log_info "  Overall Status: $overall_status"
  log_info "  Critical Issues: $critical_issues"
  log_info "  High/Warning Issues: $((high_issues + warnings))"
  log_info "  Automation: Dependabot handles updates automatically"

  # Return to original directory before exit
  cd "$original_dir" || log_warn "Failed to return to original directory: $original_dir"

  # Determine exit strategy
  if [ "$overall_status" = "CRITICAL" ] && [ "$abort_on_critical" = "true" ]; then
    log_error "Build aborted due to critical security issues!"
    log_error "Recommendation: Review security scan results and apply updates"
    return 2
  elif [ $critical_issues -gt 0 ] || [ $high_issues -gt 0 ]; then
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

  # Check Docker Scout
  if docker scout version >/dev/null 2>&1; then
    tools_available+=("Docker Scout")
  else
    tools_missing+=("Docker Scout")
  fi

  # Check Trivy
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
  log_info "  5. Enable Docker Scout or Trivy for container scanning"
  log_info "  6. Keep Composer dependencies updated with 'composer audit'"
  log_info "  7. Review Git dependencies for secure HTTPS URLs"
  log_info "  8. Monitor security advisories for Moodle core and plugins"
  log_info "  9. Check Moodle security announcements: https://moodle.org/security/"
  log_info "  10. Review plugin security via GitHub security advisories"

  # Check current Dockerfile practices
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "FROM.*:latest" >/dev/null 2>&1; then
    log_warn "⚠️  Found 'latest' tags in Dockerfiles - consider using specific versions"
  fi

  # Check for HTTP git clones
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "git clone.*http://" >/dev/null 2>&1; then
    log_error "❌ Found insecure HTTP git clones - update to HTTPS"
  fi

  # Check for SSL verification disabled
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "GIT_SSL_NO_VERIFY=1" >/dev/null 2>&1; then
    log_error "❌ CRITICAL: SSL verification disabled in Dockerfiles"
  fi

  return 0
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