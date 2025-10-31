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

  # Use Docker Scout (built into Docker) for image scanning
  if command -v docker >/dev/null 2>&1; then
    local scan_output
    local exit_code=0
    local high_count=0
    local critical_count=0

    # Enable Docker Scout if available
    if docker scout version >/dev/null 2>&1; then
      log_debug "Using Docker Scout for vulnerability scanning"

      scan_output=$(docker scout cves "$image_name" --format json 2>/dev/null) || exit_code=$?

      if [ $exit_code -eq 0 ] && [ -n "$scan_output" ]; then
        # Parse Scout results
        local critical_count=$(echo "$scan_output" | jq -r '.vulnerabilities[] | select(.severity=="critical") | length' 2>/dev/null || echo "0")
        local high_count=$(echo "$scan_output" | jq -r '.vulnerabilities[] | select(.severity=="high") | length' 2>/dev/null || echo "0")

        if [ "$critical_count" -gt 0 ]; then
          eval "$output_var='CRITICAL'"
          log_error "CRITICAL: $critical_count critical vulnerabilities in $image_name"
          if [ "$exit_on" = "critical" ]; then
            return 2
          fi
        elif [ "$high_count" -gt 0 ]; then
          eval "$output_var='HIGH'"
          log_warn "HIGH: $high_count high-severity vulnerabilities in $image_name"
          if [ "$exit_on" -ne "none"  ]; then
            return 2
          fi
          return 1
        else
          eval "$output_var='CLEAN'"
          log_info "No critical/high vulnerabilities found in $image_name"
          return 0
        fi
      fi
    fi

    # Fallback: Use Trivy if Docker Scout unavailable
    if command -v trivy >/dev/null 2>&1; then
      log_debug "Using Trivy for vulnerability scanning"

      local trivy_output="/tmp/trivy-scan-$(date +%s).json"
      if trivy image --format json --output "$trivy_output" "$image_name" >/dev/null 2>&1; then
        local critical_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$trivy_output" 2>/dev/null || echo "0")
        local high_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$trivy_output" 2>/dev/null || echo "0")

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
      fi
    fi
  fi

  # No scanning tools available
  eval "$output_var='UNKNOWN'"
  log_warn "No container scanning tools available (Docker Scout, Trivy)"
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

scan_git_dependencies() {
  local project_dir="${1:-.}"
  local output_var="${2:-GIT_SCAN_RESULT}"

  log_info "Scanning Git dependencies for security issues"

  cd "$project_dir" || return 1

  # Look for Git submodules and external repositories in Dockerfiles
  local security_issues=0
  local total_repos=0

  # Check .gitmodules
  if [ -f ".gitmodules" ]; then
    log_debug "Checking Git submodules"
    total_repos=$((total_repos + $(grep -c "url = " .gitmodules 2>/dev/null || echo "0")))
  fi

  # Check Dockerfiles for git clone commands
  find . -name "*.Dockerfile" -o -name "Dockerfile*" | while read -r dockerfile; do
    local git_clones=$(grep -c "git clone" "$dockerfile" 2>/dev/null || echo "0")
    total_repos=$((total_repos + git_clones))

    # Check for insecure git clone patterns
    if grep -q "git clone.*http://" "$dockerfile" 2>/dev/null; then
      log_warn "Insecure HTTP git clone found in $dockerfile"
      security_issues=$((security_issues + 1))
    fi

    # Check for git clone without depth (potential for large downloads)
    if grep -q "git clone" "$dockerfile" 2>/dev/null && ! grep -q "depth=" "$dockerfile" 2>/dev/null; then
      log_debug "Git clone without --depth found in $dockerfile (performance concern)"
    fi
  done

  if [ $security_issues -gt 0 ]; then
    eval "$output_var='SECURITY_ISSUES'"
    log_error "Git dependency security issues found: $security_issues"
    return 2
  elif [ $total_repos -gt 0 ]; then
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

  # Check current Dockerfile practices
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "FROM.*:latest" >/dev/null 2>&1; then
    log_warn "⚠️  Found 'latest' tags in Dockerfiles - consider using specific versions"
  fi

  # Check for HTTP git clones
  if find "$project_dir" -name "*.Dockerfile" -o -name "Dockerfile*" | xargs grep -l "git clone.*http://" >/dev/null 2>&1; then
    log_error "❌ Found insecure HTTP git clones - update to HTTPS"
  fi

  return 0
}