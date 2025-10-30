#!/bin/bash

# Version Management Utilities
# Generates dependency files from centralized version definitions

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
# VERSION MANAGEMENT UTILITIES MODULE
# =============================================================================
# 
# This module provides utilities for managing dependency versions across
# the platform while maintaining DRY principles.
# 
# NPM Dependencies: Managed in config/lighthouse/package.json (single source)
# Other Dependencies: Managed in example.versions.env (centralized)
# 
# =============================================================================

generate_lighthouse_package_json() {
  local lighthouse_dir="${1:-config/lighthouse}"
  local versions_file="${2:-example.versions.env}"

  log_info "Generating Lighthouse package.json from centralized versions..."

  # Source version definitions
  if [ -f "$versions_file" ]; then
    source "$versions_file"
  else
    log_error "Versions file not found: $versions_file"
    return 1
  fi

  # Generate package.json with centralized versions
  cat > "$lighthouse_dir/package.json" << EOF
{
  "name": "moodle-lighthouse-tests",
  "version": "1.0.0",
  "description": "Lighthouse performance testing for Moodle deployment",
  "private": true,
  "dependencies": {
    "lighthouse": "${LIGHTHOUSE_VERSION:-^11.0.0}",
    "puppeteer": "${PUPPETEER_VERSION:-^21.0.0}"
  },
  "devDependencies": {
    "jest": "^29.0.0"
  },
  "scripts": {
    "test": "lighthouse --chrome-flags='--headless --no-sandbox --disable-gpu'",
    "security-audit": "npm audit --audit-level moderate"
  },
  "engines": {
    "node": ">=18.0.0",
    "npm": ">=8.0.0"
  }
}
EOF

  log_info "✅ Generated $lighthouse_dir/package.json with centralized versions"
  log_debug "Lighthouse: ${LIGHTHOUSE_VERSION:-^11.0.0}, Puppeteer: ${PUPPETEER_VERSION:-^21.0.0}"
}

# =============================================================================
# DOCKERFILE COMPOSER DEPENDENCY INJECTION
# =============================================================================

update_dockerfile_composer_versions() {
  local dockerfile="${1:-Moodle.Dockerfile}"
  local versions_file="${2:-example.versions.env}"

  log_info "Updating Dockerfile Composer commands with centralized versions..."

  # Source version definitions
  if [ -f "$versions_file" ]; then
    # Use source for bash scripts, but handle it properly for different environments
    set -a  # Export all variables
    . "$versions_file"
    set +a  # Stop exporting
  else
    log_error "Versions file not found: $versions_file"
    return 1
  fi

  # Update ZipStream version in Dockerfile
  if [ -f "$dockerfile" ]; then
    # Replace the composer require command with versioned dependency
    sed -i.bak "s|composer require maennchen/zipstream-php.*|composer require maennchen/zipstream-php:\"${ZIPSTREAM_PHP_VERSION:-^2.1}\" --with-all-dependencies|g" "$dockerfile"

    log_info "✅ Updated $dockerfile with ZipStream version: ${ZIPSTREAM_PHP_VERSION:-^2.1}"
  else
    log_error "Dockerfile not found: $dockerfile"
    return 1
  fi
}

# =============================================================================
# DEPENDABOT CONFIGURATION GENERATION
# =============================================================================

generate_dependabot_config() {
  local output_file="${1:-.github/dependabot.yml}"
  local versions_file="${2:-example.versions.env}"

  log_info "Generating Dependabot configuration with centralized ecosystem management..."

  # Ensure .github directory exists
  mkdir -p "$(dirname "$output_file")"

  cat > "$output_file" << 'EOF'
# Dependabot configuration for comprehensive dependency management
# Automatically generated from centralized version management
version: 2
updates:
  # NPM dependencies (Lighthouse testing)
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
      - "lighthouse"
    groups:
      lighthouse-dependencies:
        patterns:
          - "lighthouse*"
          - "puppeteer*"
      security-updates:
        patterns:
          - "*"
        update-types:
          - "security"
    auto-merge:
      type: "security-updates"

  # Docker base images (centrally versioned in example.versions.env)
  - package-ecosystem: "docker"
    directory: "/"
    schedule:
      interval: "weekly"
      day: "tuesday"
      time: "09:00"
    open-pull-requests-limit: 5
    reviewers:
      - "infrastructure-team"
    labels:
      - "docker"
      - "security"
      - "base-images"
    groups:
      php-stack:
        patterns:
          - "php:*"
          - "mariadb:*"
          - "nginx*:*"
      infrastructure:
        patterns:
          - "golang:*"
          - "ubuntu:*"
          - "redis:*"
      security-updates:
        patterns:
          - "*"
        update-types:
          - "security"

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

  log_info "✅ Generated $output_file with centralized dependency management"
}

# =============================================================================
# SECURITY SCANNING FOR CONTAINERIZED BUILDS
# =============================================================================

scan_containerized_dependencies() {
  local container_name="${1:-moodle}"
  local versions_file="${2:-example.versions.env}"

  log_info "Scanning dependencies inside containerized build..."

  # Source version definitions for context
  if [ -f "$versions_file" ]; then
    source "$versions_file"
  fi

  # Check if container is running or build one temporarily for scanning
  if ! docker ps | grep -q "$container_name"; then
    log_info "Building temporary container for dependency scanning..."

    # Build container with specific tag for scanning
    docker build -f Moodle.Dockerfile -t "${container_name}:security-scan" . || {
      log_error "Failed to build container for security scanning"
      return 1
    }
  fi

  # Run security scans inside the container
  log_info "Running Composer audit inside container..."
  docker run --rm "${container_name}:security-scan" bash -c "
    cd /app/public
    composer audit --format=json 2>/dev/null || echo 'No composer.lock found or audit failed'
  "

  # Scan container image itself
  if command -v trivy >/dev/null 2>&1; then
    log_info "Running Trivy container scan..."
    trivy image --severity HIGH,CRITICAL "${container_name}:security-scan"
  elif docker scout version >/dev/null 2>&1; then
    log_info "Running Docker Scout scan..."
    docker scout cves "${container_name}:security-scan"
  else
    log_warn "No container scanning tools available"
  fi

  # Cleanup temporary container
  docker rmi "${container_name}:security-scan" >/dev/null 2>&1 || true
}

# =============================================================================
# VERSION SYNCHRONIZATION
# =============================================================================

sync_all_versions() {
  local versions_file="${1:-example.versions.env}"

  log_info "Synchronizing all dependency versions from: $versions_file"

  # 1. Generate Lighthouse package.json
  generate_lighthouse_package_json "config/lighthouse" "$versions_file"

  # 2. Update Dockerfile composer versions
  update_dockerfile_composer_versions "Moodle.Dockerfile" "$versions_file"

  # 3. Generate Dependabot configuration
  generate_dependabot_config ".github/dependabot.yml" "$versions_file"

  log_info "✅ All versions synchronized from centralized configuration"
  log_info "   - Lighthouse package.json updated"
  log_info "   - Dockerfile Composer versions updated"
  log_info "   - Dependabot configuration regenerated"
}

# =============================================================================
# VERSION VALIDATION
# =============================================================================

validate_version_consistency() {
  local versions_file="${1:-example.versions.env}"

  log_info "Validating version consistency across the platform..."

  local inconsistencies=0

  # Source versions for validation
  if [ -f "$versions_file" ]; then
    set -a
    . "$versions_file"
    set +a
  else
    log_error "Versions file not found: $versions_file"
    return 1
  fi

  # Check Lighthouse package.json consistency
  if [ -f "config/lighthouse/package.json" ]; then
    local lighthouse_pkg_version=$(jq -r '.dependencies.lighthouse // "missing"' config/lighthouse/package.json)
    local puppeteer_pkg_version=$(jq -r '.dependencies.puppeteer // "missing"' config/lighthouse/package.json)

    if [ "$lighthouse_pkg_version" != "${LIGHTHOUSE_VERSION:-^11.0.0}" ]; then
      log_warn "Version mismatch: Lighthouse package.json ($lighthouse_pkg_version) vs versions file (${LIGHTHOUSE_VERSION:-^11.0.0})"
      inconsistencies=$((inconsistencies + 1))
    fi

    if [ "$puppeteer_pkg_version" != "${PUPPETEER_VERSION:-^21.0.0}" ]; then
      log_warn "Version mismatch: Puppeteer package.json ($puppeteer_pkg_version) vs versions file (${PUPPETEER_VERSION:-^21.0.0})"
      inconsistencies=$((inconsistencies + 1))
    fi
  fi

  # Check Redis deployment script consistency
  if [ -f "openshift/scripts/deploy-redis-sentinel.sh" ]; then
    local script_redis_image=$(grep "target_redis_image=" openshift/scripts/deploy-redis-sentinel.sh | grep -v "^#" | cut -d'"' -f2 | head -1)
    local script_sentinel_image=$(grep "target_sentinel_image=" openshift/scripts/deploy-redis-sentinel.sh | grep -v "^#" | cut -d'"' -f2 | head -1)

    if [ -n "$script_redis_image" ] && [[ "$script_redis_image" != *"REDIS_IMAGE"* ]] && [ "$script_redis_image" != "${REDIS_IMAGE}" ]; then
      log_warn "Version mismatch: Redis deployment script ($script_redis_image) vs versions file (${REDIS_IMAGE})"
      inconsistencies=$((inconsistencies + 1))
    fi

    if [ -n "$script_sentinel_image" ] && [[ "$script_sentinel_image" != *"REDIS_SENTINEL_IMAGE"* ]] && [ "$script_sentinel_image" != "${REDIS_SENTINEL_IMAGE}" ]; then
      log_warn "Version mismatch: Sentinel deployment script ($script_sentinel_image) vs versions file (${REDIS_SENTINEL_IMAGE})"
      inconsistencies=$((inconsistencies + 1))
    fi
  fi

  # Check Dockerfile consistency
  if [ -f "Moodle.Dockerfile" ]; then
    local dockerfile_zipstream=$(grep "composer require maennchen/zipstream-php" Moodle.Dockerfile | grep -o '"[^"]*"' | tr -d '"')

    if [ -n "$dockerfile_zipstream" ] && [ "$dockerfile_zipstream" != "${ZIPSTREAM_PHP_VERSION:-^2.1}" ]; then
      log_warn "Version mismatch: Dockerfile ZipStream ($dockerfile_zipstream) vs versions file (${ZIPSTREAM_PHP_VERSION:-^2.1})"
      inconsistencies=$((inconsistencies + 1))
    fi
  fi

  if [ $inconsistencies -eq 0 ]; then
    log_info "✅ All versions are consistent across the platform"
    return 0
  else
    log_error "❌ Found $inconsistencies version inconsistencies"
    log_info "Run 'sync_all_versions' to fix inconsistencies"
    return 1
  fi
}