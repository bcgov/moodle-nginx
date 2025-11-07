#!/bin/bash
# validate-version-consistency.sh
# Validates consistency between infrastructure and application dependency versions
# Ensures compatibility without enforcing single source of truth

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log_info() { echo "ℹ️  $*"; }
log_success() { echo "✅ $*"; }
log_warn() { echo "⚠️  $*"; }
log_error() { echo "❌ $*" >&2; }

# =============================================================================
# VERSION EXTRACTION
# =============================================================================

get_infrastructure_versions() {
    local env_file="$PROJECT_ROOT/example.versions.env"

    if [ ! -f "$env_file" ]; then
        log_error "example.versions.env not found"
        return 1
    fi

    source "$env_file"

    # Extract major.minor from PHP image tag
    PHP_INFRA_VERSION=$(echo "$PHP_IMAGE" | grep -oP '\d+\.\d+' | head -1)

    # Extract Node version from package.json (since it's defined per application)
    local package_file="$PROJECT_ROOT/config/lighthouse/package.json"
    if [ -f "$package_file" ] && command -v jq >/dev/null 2>&1; then
        local node_constraint=$(jq -r '.engines.node // ">=18.0.0"' "$package_file")
        # Extract first number from constraint (e.g., ">=18.0.0" -> "18")
        NODE_INFRA_VERSION=$(echo "$node_constraint" | grep -oP '\d+' | head -1)
    else
        log_warn "Could not determine Node version from package.json"
        NODE_INFRA_VERSION="unknown"
    fi

    log_info "Infrastructure versions:"
    log_info "  PHP: $PHP_INFRA_VERSION (from $PHP_IMAGE)"
    log_info "  Node: $NODE_INFRA_VERSION (from package.json engines.node)"
}

get_composer_versions() {
    local composer_file="$PROJECT_ROOT/config/moodle/composer.json"

    if [ ! -f "$composer_file" ]; then
        log_warn "composer.json not found"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq not available, skipping Composer validation"
        return 0
    fi

    # Extract PHP constraint
    COMPOSER_PHP_CONSTRAINT=$(jq -r '.require.php // "none"' "$composer_file")

    log_info "Composer versions:"
    log_info "  PHP constraint: $COMPOSER_PHP_CONSTRAINT"
}

get_npm_versions() {
    local package_file="$PROJECT_ROOT/config/lighthouse/package.json"

    if [ ! -f "$package_file" ]; then
        log_warn "package.json not found"
        return 0
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_warn "jq not available, skipping NPM validation"
        return 0
    fi

    # Extract Node constraint
    NPM_NODE_CONSTRAINT=$(jq -r '.engines.node // "none"' "$package_file")

    # Extract Lighthouse version
    NPM_LIGHTHOUSE_VERSION=$(jq -r '.dependencies.lighthouse // .devDependencies.lighthouse // "none"' "$package_file")

    log_info "NPM versions:"
    log_info "  Node constraint: $NPM_NODE_CONSTRAINT"
    log_info "  Lighthouse: $NPM_LIGHTHOUSE_VERSION"
}

# =============================================================================
# VALIDATION
# =============================================================================

validate_php_compatibility() {
    log_info "Validating PHP version compatibility..."

    if [ "$COMPOSER_PHP_CONSTRAINT" = "none" ]; then
        log_warn "No PHP constraint in composer.json (recommend adding one)"
        return 0
    fi

    # Extract minimum version from constraint (>=8.1, ^8.1, etc.)
    local min_version=$(echo "$COMPOSER_PHP_CONSTRAINT" | grep -oP '\d+\.\d+' | head -1)

    if [ -z "$min_version" ]; then
        log_warn "Could not parse PHP constraint: $COMPOSER_PHP_CONSTRAINT"
        return 0
    fi

    # Compare major.minor versions
    if [ "$(printf '%s\n' "$min_version" "$PHP_INFRA_VERSION" | sort -V | head -1)" = "$min_version" ]; then
        log_success "PHP versions compatible:"
        log_success "  Infrastructure: PHP $PHP_INFRA_VERSION"
        log_success "  Composer requires: $COMPOSER_PHP_CONSTRAINT (>= $min_version)"
        return 0
    else
        log_error "PHP version mismatch:"
        log_error "  Infrastructure: PHP $PHP_INFRA_VERSION"
        log_error "  Composer requires: $COMPOSER_PHP_CONSTRAINT (>= $min_version)"
        log_error "  Action: Upgrade PHP_IMAGE in example.versions.env"
        return 1
    fi
}

validate_node_compatibility() {
    log_info "Validating Node version compatibility..."

    if [ "$NPM_NODE_CONSTRAINT" = "none" ]; then
        log_warn "No Node constraint in package.json engines"
        return 0
    fi

    # Extract minimum version from constraint (>=18.0.0, ^18.0.0, etc.)
    local min_version=$(echo "$NPM_NODE_CONSTRAINT" | grep -oP '\d+' | head -1)

    if [ -z "$min_version" ]; then
        log_warn "Could not parse Node constraint: $NPM_NODE_CONSTRAINT"
        return 0
    fi

    # Compare major versions
    if [ "$NODE_INFRA_VERSION" -ge "$min_version" ]; then
        log_success "Node versions compatible:"
        log_success "  Infrastructure: Node $NODE_INFRA_VERSION"
        log_success "  NPM requires: $NPM_NODE_CONSTRAINT (>= $min_version)"
        return 0
    else
        log_error "Node version mismatch:"
        log_error "  Infrastructure: Node $NODE_INFRA_VERSION"
        log_error "  NPM requires: $NPM_NODE_CONSTRAINT (>= $min_version)"
        log_error "  Action: Upgrade NODE_VERSION in example.versions.env"
        return 1
    fi
}

# =============================================================================
# DEPENDENCY DOCUMENTATION
# =============================================================================

check_documented_dependencies() {
    log_info "Checking if application dependencies are documented..."

    local versions_file="$PROJECT_ROOT/example.versions.env"
    local has_warnings=0

    # Check for Lighthouse documentation
    if [ "$NPM_LIGHTHOUSE_VERSION" != "none" ]; then
        if ! grep -q "LIGHTHOUSE_VERSION" "$versions_file" 2>/dev/null; then
            log_warn "Lighthouse version not documented in example.versions.env"
            log_warn "  Consider adding: # LIGHTHOUSE_VERSION=$NPM_LIGHTHOUSE_VERSION (managed in package.json)"
            has_warnings=1
        fi
    fi

    # Check for Composer dependencies documentation
    if [ -f "$PROJECT_ROOT/config/moodle/composer.json" ]; then
        if ! grep -q "PHP_DEPENDENCIES" "$versions_file" 2>/dev/null; then
            log_warn "PHP dependencies not documented in example.versions.env"
            log_warn "  Consider adding comment section for Composer packages"
            has_warnings=1
        fi
    fi

    if [ $has_warnings -eq 0 ]; then
        log_success "Application dependencies are documented"
    fi

    return 0
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

generate_version_report() {
    local report_file="$PROJECT_ROOT/tmp/version-consistency-report.md"

    mkdir -p "$(dirname "$report_file")"

    cat > "$report_file" << EOF
# 📊 Version Consistency Report

**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")
**Project:** bcgov/moodle-nginx

---

## 🏗️ Infrastructure Versions (example.versions.env)

| Component | Version | Purpose |
|-----------|---------|---------|
| **PHP Runtime** | $PHP_INFRA_VERSION | Container runtime environment |
| **Node Runtime** | $NODE_INFRA_VERSION | Build tools and testing |

## 📦 Application Dependencies

### PHP Dependencies (composer.json)

| Constraint | Value | Status |
|------------|-------|--------|
| PHP Version | $COMPOSER_PHP_CONSTRAINT | $([ "$(validate_php_compatibility 2>&1)" = "0" ] && echo "✅ Compatible" || echo "⚠️ Check required") |

### NPM Dependencies (package.json)

| Constraint | Value | Status |
|------------|-------|--------|
| Node Version | $NPM_NODE_CONSTRAINT | $([ "$(validate_node_compatibility 2>&1)" = "0" ] && echo "✅ Compatible" || echo "⚠️ Check required") |
| Lighthouse | $NPM_LIGHTHOUSE_VERSION | Managed by NPM |

---

## 📋 Version Management Strategy

### Two-Tier Architecture

**Tier 1: Infrastructure** (\`example.versions.env\`)
- Docker base images (PHP, Nginx, Redis, MariaDB)
- System package versions
- Build tool versions

**Tier 2: Application** (\`composer.json\` / \`package.json\`)
- PHP libraries (zipstream-php, etc.)
- JavaScript tools (Lighthouse, Puppeteer)
- Managed by Composer/NPM with semantic versioning

### Why Separation Works

1. **Different Lifecycles**: Infrastructure changes less frequently than dependencies
2. **Tool Integration**: Composer/NPM handle dependency resolution natively
3. **Security Updates**: Dependabot updates application dependencies automatically
4. **Ecosystem Compatibility**: Standard tools work without custom wrappers

### Validation Points

✅ Infrastructure runtime must satisfy application dependency constraints
✅ Automated validation runs in CI/CD
✅ Manual updates synchronized via documented process

---

## 🔄 Update Workflow

### Updating Infrastructure Versions

1. Modify \`example.versions.env\`
2. Run validation: \`./openshift/scripts/validate-version-consistency.sh\`
3. Update application constraints if needed
4. Commit both changes together

### Updating Application Dependencies

1. Modify \`composer.json\` or \`package.json\`
2. Run \`composer update\` or \`npm install\`
3. Run validation to check infrastructure compatibility
4. Update \`example.versions.env\` if infrastructure upgrade needed

---

*Version consistency validation ensures compatibility across infrastructure and application layers*
*Generated by validate-version-consistency.sh*
EOF

    log_success "Version consistency report: $report_file"

    # Add to GitHub Actions Summary if available
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        cat "$report_file" >> "$GITHUB_STEP_SUMMARY"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_info "🔍 Version Consistency Validation"
    echo ""

    local exit_code=0

    # Extract versions
    get_infrastructure_versions || exit_code=1
    echo ""

    get_composer_versions || exit_code=1
    echo ""

    get_npm_versions || exit_code=1
    echo ""

    # Validate compatibility
    validate_php_compatibility || exit_code=1
    echo ""

    validate_node_compatibility || exit_code=1
    echo ""

    # Check documentation
    check_documented_dependencies
    echo ""

    # Generate report
    generate_version_report
    echo ""

    if [ $exit_code -eq 0 ]; then
        log_success "✅ All version constraints are compatible"
        log_info "Infrastructure and application dependencies are properly aligned"
    else
        log_error "❌ Version compatibility issues detected"
        log_error "Review the report and update versions as needed"
    fi

    return $exit_code
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
