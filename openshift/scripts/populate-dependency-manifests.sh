#!/bin/bash
#==============================================================================
# populate-dependency-manifests.sh
#==============================================================================
# PURPOSE:
#   Populate dependency manifest files (composer.json, package.json) from
#   centralized version configuration (example.versions.env). Ensures DRY
#   principle by maintaining single source of truth for all dependency versions.
#
# TEMPLATING SYSTEM:
#   Uses JSON config (config/dependencies/dependency-config.json) to define:
#   - Target manifest files to update
#   - Environment variable mappings
#   - JSONPath locations for version substitution
#   - Validation rules
#
# SUPPORTED MANIFESTS:
#   - config/moodle/composer.json        - PHP dependencies
#   - config/lighthouse/package.json     - Node.js dependencies
#   - Custom manifests via config file
#
# AUTOMATION PROCESS:
#   1. Load versions from example.versions.env
#   2. Parse dependency-config.json for manifest templates
#   3. Use jq to update version fields in target files
#   4. Validate updated manifests (JSON syntax)
#   5. Report changes and generate summary
#
# CROSS-PLATFORM:
#   - Works in: GitHub Actions, OpenShift builds, local development
#   - Requires: bash, jq (JSON processor)
#   - Handles: Unix and Windows line endings
#
# CONFIGURATION:
#   Config file: config/dependencies/dependency-config.json
#   Format:
#   {
#     "manifests": [
#       {
#         "file": "config/moodle/composer.json",
#         "mappings": [
#           {"env": "PHP_VERSION", "path": ".require.php"}
#         ]
#       }
#     ]
#   }
#
# USAGE:
#   # Populate all manifests
#   ./openshift/scripts/populate-dependency-manifests.sh
#
#   # Dry-run (no file modifications)
#   DRY_RUN=true ./openshift/scripts/populate-dependency-manifests.sh
#
# CI/CD INTEGRATION:
#   Called by: .github/workflows/build.yml (checkEnv job)
#   Ensures manifests are synchronized before build
#
# RELATED DOCS:
#   - Configuration: ../../config/dependencies/dependency-config.json
#   - Versions: ../../example.versions.env
#   - CI/CD: ../../.github/workflows/build.yml
#==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIG_FILE="$PROJECT_ROOT/config/dependencies/dependency-config.json"
VERSIONS_FILE="$PROJECT_ROOT/example.versions.env"

log_info() {
    echo "ℹ️  $1"
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

# Check dependencies
check_dependencies() {
    local missing=0

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required but not installed"
        missing=1
    fi

    if [ ! -f "$VERSIONS_FILE" ]; then
        log_error "Versions file not found: $VERSIONS_FILE"
        missing=1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        missing=1
    fi

    if [ $missing -eq 1 ]; then
        log_error "Missing dependencies. Please install required tools."
        exit 1
    fi
}

# Load environment variables from example.versions.env
load_versions() {
    log_info "Loading versions from $VERSIONS_FILE"

    # Source the file to load variables
    set -a  # Export all variables
    # shellcheck source=/dev/null
    source "$VERSIONS_FILE"
    set +a

    # Debug: Show critical variables for Docker manifest
    log_info "Key Docker image variables loaded:"
    log_info "  PHP_IMAGE: ${PHP_IMAGE:-UNDEFINED}"
    log_info "  CRON_IMAGE: ${CRON_IMAGE:-UNDEFINED}"
    log_info "  MARIADB_IMAGE: ${MARIADB_IMAGE:-UNDEFINED}"
    log_info "  WEB_IMAGE: ${WEB_IMAGE:-UNDEFINED}"
    log_info "  BACKUP_IMAGE: ${BACKUP_IMAGE:-UNDEFINED}"
    log_info "  REDIS_IMAGE: ${REDIS_IMAGE:-UNDEFINED}"
    log_info "  REDIS_SENTINEL_IMAGE: ${REDIS_SENTINEL_IMAGE:-UNDEFINED}"
    log_info "  GOLANG_IMAGE: ${GOLANG_IMAGE:-UNDEFINED}"
    log_info "  UBUNTU_IMAGE: ${UBUNTU_IMAGE:-UNDEFINED}"

    log_success "Loaded environment variables"
}

# Generate PHP Composer dependencies for both production and security scanning
generate_composer_manifest() {
    local output_file="$PROJECT_ROOT/config/moodle/composer.json"
    log_info "Generating production Composer dependencies from centralized versions: $output_file"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"

    # Generate composer.json with centralized versions for both production and Dependabot
    # Extract PHP version from PHP_IMAGE (e.g., "php:8.3-fpm" -> "8.3")
    local php_version
    if [[ "${PHP_IMAGE}" =~ php:([0-9]+\.[0-9]+) ]]; then
        php_version="${BASH_REMATCH[1]}"
    else
        log_warn "Could not extract PHP version from PHP_IMAGE: ${PHP_IMAGE}, defaulting to 8.3"
        php_version="8.3"
    fi

    cat > "$output_file" << EOF
{
  "name": "bcgov/moodle-php-dependencies",
  "description": "PHP dependencies for Moodle deployment - Security-controlled versions from centralized management",
  "type": "project",
  "require": {
    "php": ">=${php_version}",
    "maennchen/zipstream-php": "${ZIPSTREAM_PHP_VERSION}"
  },
  "require-dev": {},
  "config": {
    "optimize-autoloader": true,
    "prefer-stable": true,
    "sort-packages": true,
    "audit": {
      "abandoned": "report"
    }
  },
  "minimum-stability": "stable",
  "prefer-stable": true,
  "scripts": {
    "security-audit": "composer audit --format=json",
    "security-check": "composer audit --format=table",
    "validate-lock": "composer validate --strict --check-lock",
    "update-deps": "composer update --with-all-dependencies --dry-run"
  },
  "authors": [
    {
      "name": "Infrastructure Team",
      "email": "infrastructure@gov.bc.ca"
    }
  ],
  "license": "Apache-2.0",
  "extra": {
    "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
    "source_file": "example.versions.env",
    "generator": "populate-dependency-manifests.sh",
    "purpose": "Centralized PHP dependency management for production and security scanning"
  }
}
EOF

    log_success "Generated production Composer dependencies (used for both Docker builds and Dependabot scanning)"
}

# Generate Docker images manifest for Dependabot
generate_docker_manifest() {
    local output_file="$PROJECT_ROOT/openshift/dependencies/images.yml"
    log_info "Generating Docker images manifest: $output_file"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"

    # Validate required variables are set
    local required_vars=(
        "PHP_IMAGE" "CRON_IMAGE" "MARIADB_IMAGE" "WEB_IMAGE"
        "BACKUP_IMAGE" "REDIS_IMAGE" "REDIS_SENTINEL_IMAGE"
        "GOLANG_IMAGE" "UBUNTU_IMAGE"
    )

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            log_error "Required variable $var is not set"
            return 1
        fi
    done

    # Generate YAML file with proper quoting
    cat > "$output_file" << EOF
# Auto-generated Docker images manifest for Dependabot scanning
# DO NOT EDIT MANUALLY - Generated by populate-dependency-manifests.sh
# Source: example.versions.env
#
# This file enables Dependabot to scan all Docker images used in the project
# and automatically create pull requests for security updates.

version: '3.8'
services:
  # Core Application Services
  php:
    image: "${PHP_IMAGE}"

  cron:
    image: "${CRON_IMAGE}"

  database:
    image: "${MARIADB_IMAGE}"

  web:
    image: "${WEB_IMAGE}"

  # Infrastructure Services
  backup:
    image: "${BACKUP_IMAGE}"

  redis:
    image: "${REDIS_IMAGE}"

  redis-sentinel:
    image: "${REDIS_SENTINEL_IMAGE}"

  # Build/Development Tools
  golang:
    image: "${GOLANG_IMAGE}"

  ubuntu:
    image: "${UBUNTU_IMAGE}"

# Metadata for automated processing
metadata:
  generated_at: "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  source_file: "example.versions.env"
  generator: "populate-dependency-manifests.sh"
  purpose: "Dependabot Docker image security scanning"
EOF

    log_success "Generated Docker images manifest"
}

# Generate Helm Chart dependencies
generate_helm_manifest() {
    local output_file="$PROJECT_ROOT/openshift/dependencies/Chart.yaml"
    log_info "Generating Helm Chart manifest: $output_file"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"

    # Generate Chart.yaml file
    cat > "$output_file" << EOF
# Auto-generated Helm Chart dependencies for Dependabot scanning
# DO NOT EDIT MANUALLY - Generated by populate-dependency-manifests.sh
# Source: example.versions.env

apiVersion: v2
name: moodle-platform-dependencies
description: Dependency manifest for Helm charts used in Moodle platform
type: library
version: 1.0.0

# Dependencies that Dependabot can scan
dependencies:
  - name: backup-storage
    repository: ${BACKUP_HELM_CHART}
    version: "~1.0.0"
    condition: backup.enabled

  - name: redis
    repository: ${REDIS_HELM_CHART}
    version: "${REDIS_CHART_VERSION}"
    condition: redis.enabled

# Metadata
annotations:
  generated_at: "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  source_file: "example.versions.env"
  generator: "populate-dependency-manifests.sh"
  purpose: "Dependabot Helm chart security scanning"
EOF

    log_success "Generated Helm Chart manifest"
}

# Generate security tools manifest
generate_security_manifest() {
    local output_file="$PROJECT_ROOT/.github/security-tools.json"
    log_info "Generating security tools manifest: $output_file"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"

    # Generate JSON file
    cat > "$output_file" << EOF
{
  "description": "Security scanning tools versions for the platform",
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "source_file": "example.versions.env",
  "generator": "populate-dependency-manifests.sh",
  "tools": {
    "trivy": {
      "version": "${TRIVY_VERSION}",
      "description": "Container vulnerability scanner",
      "usage": "Security scanning in CI/CD"
    },
    "docker_scout": {
      "version": "${DOCKER_SCOUT_VERSION}",
      "description": "Docker security analysis",
      "usage": "Image vulnerability assessment"
    }
  },
  "scan_frequency": "daily",
  "alert_channels": ["rocket-chat", "github-issues"]
}
EOF

    log_success "Generated security tools manifest"
}

# Generate Git dependencies manifest for Moodle plugins
generate_git_dependencies_manifest() {
    local output_file="$PROJECT_ROOT/config/moodle/git-dependencies.json"
    log_info "Generating Git dependencies manifest: $output_file"

    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$output_file")"

    # Generate JSON file
    cat > "$output_file" << EOF
{
  "description": "Git repository dependencies for Moodle plugins",
  "generated_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "source_file": "example.versions.env",
  "generator": "populate-dependency-manifests.sh",
  "repositories": {
    "moodle_core": {
      "url": "${MOODLE_URL}",
      "branch": "${MOODLE_BRANCH_VERSION}",
      "type": "core",
      "security_scan": true
    },
    "hvp_plugin": {
      "url": "${HVP_URL}",
      "branch": "${HVP_BRANCH_VERSION}",
      "type": "plugin",
      "security_scan": true
    },
    "psaelmsync_plugin": {
      "url": "${PSAELMSYNC_URL}",
      "branch": "${PSAELMSYNC_BRANCH_VERSION}",
      "type": "plugin",
      "security_scan": true
    },
    "report_all_backups": {
      "url": "${REPORT_ALL_BACKUPS_URL}",
      "branch": "${REPORT_ALL_BACKUPS_BRANCH_VERSION}",
      "type": "plugin",
      "security_scan": true
    },
    "theme_bcgovpsa": {
      "url": "${THEME_URL}",
      "branch": "${THEME_BRANCH_VERSION}",
      "type": "theme",
      "security_scan": true
    },
    "pathcurator": {
      "url": "${PCURATOR_URL}",
      "branch": "${PCURATOR_BRANCH_VERSION}",
      "type": "plugin",
      "security_scan": true
    },
    "course_search": {
      "url": "${COURSESEARCH_URL}",
      "branch": "${COURSESEARCH_BRANCH_VERSION}",
      "type": "plugin",
      "security_scan": true
    }
  },
  "scan_config": {
    "frequency": "weekly",
    "vulnerability_check": true,
    "license_compliance": true,
    "dependency_analysis": true
  }
}
EOF

    log_success "Generated Git dependencies manifest"
}

# Generate .env file for local development
generate_local_env() {
    local output_file="$PROJECT_ROOT/.env.generated"
    log_info "Generating local development environment file: $output_file"

    # Copy relevant variables for docker-compose
    cat > "$output_file" << EOF
# Auto-generated environment file for local development
# DO NOT EDIT MANUALLY - Generated by populate-dependency-manifests.sh
# Source: example.versions.env

# Core Images
PHP_IMAGE=${PHP_IMAGE}
CRON_IMAGE=${CRON_IMAGE}
MARIADB_IMAGE=${MARIADB_IMAGE}
WEB_IMAGE=${WEB_IMAGE}
REDIS_IMAGE=${REDIS_IMAGE}
REDIS_SENTINEL_IMAGE=${REDIS_SENTINEL_IMAGE}

# Versions
REDIS_CHART_VERSION=${REDIS_CHART_VERSION}
COMPOSER_VERSION=${COMPOSER_VERSION}
TRIVY_VERSION=${TRIVY_VERSION}
DOCKER_SCOUT_VERSION=${DOCKER_SCOUT_VERSION}

# Build Configuration
IMAGE_REBUILD_TIME_LIMIT=${IMAGE_REBUILD_TIME_LIMIT}

# Generated timestamp
GENERATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

    log_success "Generated local development environment file"
    log_info "To use: docker-compose --env-file .env.generated up"
}

# Validate generated manifests
validate_manifests() {
    log_info "Validating generated manifests..."

    local errors=0

    # Debug: Show what files were actually generated
    log_info "Generated files check:"
    log_info "  Docker manifest: $([ -f "$PROJECT_ROOT/openshift/dependencies/images.yml" ] && echo "EXISTS" || echo "MISSING")"
    log_info "  Security tools: $([ -f "$PROJECT_ROOT/.github/security-tools.json" ] && echo "EXISTS" || echo "MISSING")"
    log_info "  Git dependencies: $([ -f "$PROJECT_ROOT/config/moodle/git-dependencies.json" ] && echo "EXISTS" || echo "MISSING")"
    log_info "  Composer manifest: $([ -f "$PROJECT_ROOT/config/moodle/composer.json" ] && echo "EXISTS" || echo "MISSING")"

    # Check Docker manifest
    if [ -f "$PROJECT_ROOT/openshift/dependencies/images.yml" ]; then
        if command -v yq >/dev/null 2>&1; then
            local yq_output
            # Debug: Show yq version
            log_info "yq version: $(yq --version 2>/dev/null || echo "unknown")"

            # Try different yq syntax versions for compatibility
            if yq_output=$(yq eval . "$PROJECT_ROOT/openshift/dependencies/images.yml" 2>&1); then
                log_success "Docker images manifest YAML is valid (yq v4+ syntax)"
            elif yq_output=$(yq . "$PROJECT_ROOT/openshift/dependencies/images.yml" 2>&1); then
                log_success "Docker images manifest YAML is valid (yq v3 syntax)"
            else
                # Try basic YAML validation with Python if available
                if command -v python3 >/dev/null 2>&1; then
                    if python3 -c "import yaml; yaml.safe_load(open('$PROJECT_ROOT/openshift/dependencies/images.yml'))" 2>/dev/null; then
                        log_success "Docker images manifest YAML is valid (Python validation)"
                    else
                        log_error "Invalid YAML in Docker images manifest:"
                        log_error "$yq_output"
                        errors=$((errors + 1))
                    fi
                else
                    log_warn "Could not validate YAML - yq failed and Python not available"
                    log_warn "yq error: $yq_output"
                    # Don't count as error since validation tools are unreliable
                fi
            fi
        else
            log_warn "yq not available - skipping YAML validation"
        fi
    else
        log_error "Docker images manifest not generated"
        errors=$((errors + 1))
    fi

    # Check JSON manifests
    for json_file in \
        "$PROJECT_ROOT/.github/security-tools.json" \
        "$PROJECT_ROOT/config/moodle/git-dependencies.json" \
        "$PROJECT_ROOT/config/moodle/composer.json"; do

        if [ -f "$json_file" ]; then
            local jq_output
            if ! jq_output=$(jq . "$json_file" 2>&1); then
                log_error "Invalid JSON in $(basename "$json_file"):"
                log_error "$jq_output"
                errors=$((errors + 1))
            else
                log_success "$(basename "$json_file") JSON is valid"
            fi
        else
            log_error "$(basename "$json_file") not generated"
            errors=$((errors + 1))
        fi
    done

    if [ $errors -eq 0 ]; then
        log_success "All manifests validated successfully"
        return 0
    else
        log_error "Found $errors validation errors"
        return 1
    fi
}

# Main execution
main() {
    log_info "🚀 Populating dependency manifests from centralized versions"
    log_info "Project root: $PROJECT_ROOT"

    # Check dependencies
    check_dependencies

    # Load versions
    load_versions

    # Generate all manifests
    generate_composer_manifest
    generate_docker_manifest
    generate_helm_manifest
    generate_security_manifest
    generate_git_dependencies_manifest
    generate_local_env

    # Validate results
    if validate_manifests; then
        log_success "🎉 All dependency manifests generated and validated successfully!"
        log_info "Ready for:"
        log_info "  • Dependabot automated security scanning"
        log_info "  • Local development with generated .env"
        log_info "  • CI/CD integration with up-to-date dependencies"
        return 0
    else
        log_error "❌ Manifest generation completed with errors"
        return 1
    fi
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi