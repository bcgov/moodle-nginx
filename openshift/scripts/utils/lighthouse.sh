#!/bin/bash

# Lighthouse Testing Utilities Module
# Contains Lighthouse performance testing, audit reporting, and optimization helpers

# Get the directory where this script is located (local to avoid conflicts)
_LIGHTHOUSE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the core OpenShift utilities for logging functions
if [[ -f "$_LIGHTHOUSE_SCRIPT_DIR/openshift.sh" ]]; then
  source "$_LIGHTHOUSE_SCRIPT_DIR/openshift.sh"
else
  # Fallback: Define minimal logging functions if openshift.sh not found
  log_info() { echo "ℹ️  $*"; }
  log_warn() { echo "⚠️  $*"; }
  log_error() { echo "❌ $*"; }
  log_debug() { echo "🔍 Debug: $*"; }
  log_success() { echo "✅ $*"; }
fi

# =============================================================================
# LIGHTHOUSE EXECUTION
# =============================================================================

run_lighthouse_audit() {
  local url="$1"
  local config_dir="${2:-config/lighthouse}"
  local output_dir="${3:-tmp/artifacts}"
  local auth_username="${4:-}"
  local auth_password="${5:-}"

  log_info "Running Lighthouse audit for: $url"

  # Ensure output directory exists
  mkdir -p "$output_dir"

  cd "$config_dir" || {
    log_error "Failed to change to config directory: $config_dir"
    return 1
  }

  # Set authentication if provided
  if [ -n "$auth_username" ] && [ -n "$auth_password" ]; then
    export USERNAME="$auth_username"
    export PASSWORD="$auth_password"
    log_debug "Authentication credentials set"
  fi

  # Set the target URL
  export APP_HOST_URL="$url"

  # Run lighthouse with error handling
  local lighthouse_output
  local exit_code

  log_debug "Executing Lighthouse with auth script..."
  lighthouse_output=$(node lighthouse-auth.js 2>&1)
  exit_code=$?

  # Process results
  local status="failure"
  local warnings=""

  if [ $exit_code -eq 0 ]; then
    status="success"
    local warn_count=$(echo "$lighthouse_output" | grep -i warning | wc -l)
    if [ "$warn_count" -gt 0 ]; then
      warnings=" ($warn_count warnings)"
    fi
    log_info "Lighthouse audit completed successfully$warnings"
  else
    local error_message=$(echo "$lighthouse_output" | head -n 1 | sed 's/[^a-zA-Z0-9 .,;:_-]//g')
    warnings=" (Error: $error_message)"
    log_error "Lighthouse audit failed: $error_message"
  fi

  # Save full output
  echo "$lighthouse_output" > "../../$output_dir/lighthouse-full.log"

  # Return status information
  echo "${status}${warnings}"
  return $exit_code
}

# =============================================================================
# LIGHTHOUSE SETUP AND DEPENDENCY MANAGEMENT
# =============================================================================

setup_lighthouse_environment() {
  local config_dir="${1:-config/lighthouse}"
  local use_cached="${2:-true}"

  log_info "Setting up Lighthouse testing environment..."

  # Ensure we're in workspace root (important if called after other functions that cd)
  local workspace_root="${GITHUB_WORKSPACE:-.}"
  if [ -n "$GITHUB_WORKSPACE" ]; then
    cd "$GITHUB_WORKSPACE" || {
      log_error "Failed to change to workspace root: $GITHUB_WORKSPACE"
      return 1
    }
    log_debug "Changed to workspace root: $GITHUB_WORKSPACE"
  fi

  # Verify the directory exists before attempting to install
  if [ ! -d "$config_dir" ]; then
    log_error "Lighthouse config directory not found: $config_dir"
    log_error "Current directory: $(pwd)"
    log_error "Directory listing: $(ls -la | head -5)"
    return 1
  fi

  # Verify package.json exists
  if [ ! -f "$config_dir/package.json" ]; then
    log_error "package.json not found in: $config_dir"
    log_error "Expected file: $config_dir/package.json"
    log_error "Directory contents: $(ls -la $config_dir/ 2>/dev/null || echo 'directory not accessible')"
    return 1
  fi

  log_debug "Found package.json in $config_dir"

  # Source npm utilities from workspace root (don't cd first)
  source "./openshift/scripts/utils/npm.sh"

  # Install dependencies with security validation (npm_install_secure will cd into the directory)
  if npm_install_secure "$config_dir" "auto" "true"; then
    log_info "Lighthouse dependencies installed and validated"
  else
    log_error "Failed to install or validate Lighthouse dependencies"
    return 1
  fi

  # Return to workspace root after npm_install_secure (it may have changed directory)
  cd "$workspace_root" || {
    log_error "Failed to return to workspace root: $workspace_root"
    return 1
  }

  # Verify required packages (now cd from workspace root)
  cd "$config_dir" || {
    log_error "Failed to change to config directory for verification: $config_dir"
    return 1
  }

  if ! npm list lighthouse puppeteer --depth=0 >/dev/null 2>&1; then
    log_error "Required Lighthouse packages not found"
    return 1
  fi

  # Return to workspace root
  cd "$workspace_root" > /dev/null || cd - > /dev/null || cd ../..

  log_info "Lighthouse environment ready"
  return 0
}

# =============================================================================
# CACHE MANAGEMENT
# =============================================================================

get_lighthouse_cache_key() {
  local config_dir="${1:-config/lighthouse}"
  local runner_os="${2:-linux}"

  if [ -f "$config_dir/package.json" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      local package_hash=$(sha256sum "$config_dir/package.json" | cut -d' ' -f1 | head -c 12)
    elif command -v shasum >/dev/null 2>&1; then
      local package_hash=$(shasum -a 256 "$config_dir/package.json" | cut -d' ' -f1 | head -c 12)
    else
      local package_hash="nohash"
    fi

    echo "${runner_os}-lighthouse-${package_hash}-v3"
  else
    echo "${runner_os}-lighthouse-nopackage-v3"
  fi
}

display_cache_information() {
  local config_dir="${1:-config/lighthouse}"
  local cache_limit="${2:-10GB}"
  local repository="${3:-unknown/unknown}"

  log_info "=== GitHub Actions Cache Information ==="
  log_info "Repository cache limit: $cache_limit"
  log_info "Cache retention: 7 days (if unused)"
  log_info "Current cache usage can be viewed at:"
  log_info "https://github.com/$repository/actions/caches"
  log_info ""

  # NPM cache info
  source "../../openshift/scripts/utils/npm.sh"
  get_npm_cache_info "$config_dir"

  log_info ""
  log_info "=== Package Information ==="
  cd "$config_dir" || return 1

  if [ -f "package.json" ]; then
    local cache_key=$(get_lighthouse_cache_key "$config_dir")
    log_info "Cache key: $cache_key"

    if [ -f "package-lock.json" ]; then
      local line_count=$(wc -l < package-lock.json)
      log_info "package-lock.json exists ($line_count lines)"
    else
      log_info "package-lock.json not found - will be generated on install"
    fi
  fi
}

# =============================================================================
# CHROME/BROWSER SETUP
# =============================================================================

setup_chrome_dependencies() {
  local use_cache="${1:-true}"

  log_info "Setting up Chrome browser dependencies..."

  # Define packages needed for Chrome/Puppeteer
  local chrome_packages=(
    "gconf-service" "libasound2" "libatk1.0-0" "libc6" "libcairo2" "libcups2"
    "libdbus-1-3" "libexpat1" "libfontconfig1" "libgcc1" "libgconf-2-4"
    "libgdk-pixbuf2.0-0" "libglib2.0-0" "libgtk-3-0" "libnspr4" "libpango-1.0-0"
    "libpangocairo-1.0-0" "libstdc++6" "libx11-6" "libx11-xcb1" "libxcb1"
    "libxcomposite1" "libxcursor1" "libxdamage1" "libxext6" "libxfixes3"
    "libxi6" "libxrandr2" "libxrender1" "libxss1" "libxtst6" "ca-certificates"
    "fonts-liberation" "libappindicator1" "libnss3" "lsb-release" "xdg-utils"
    "wget" "libgbm-dev"
  )

  if [ "$use_cache" = "true" ]; then
    log_debug "Chrome dependencies will be cached automatically"
  else
    log_info "Installing Chrome dependencies..."
    local package_list=$(printf " %s" "${chrome_packages[@]}")
    if sudo apt-get update && sudo apt-get install -y $package_list; then
      log_info "Chrome dependencies installed successfully"
    else
      log_error "Failed to install Chrome dependencies"
      return 1
    fi
  fi

  return 0
}

# =============================================================================
# ARTIFACT MANAGEMENT
# =============================================================================

collect_lighthouse_artifacts() {
  local config_dir="${1:-config/lighthouse}"
  local output_dir="${2:-tmp/artifacts}"
  local workspace_dir="${3:-.}"

  log_info "Collecting Lighthouse artifacts..."

  # Ensure output directory exists
  mkdir -p "$output_dir"

  # Collect generated files
  local artifact_count=0

  # Look for common Lighthouse output files
  for pattern in "*.png" "*.jpg" "*.html" "*.json" "lighthouse-*.log" "*.md"; do
    if find "$workspace_dir" -name "$pattern" -not -path "*/node_modules/*" -print0 2>/dev/null | grep -zq .; then
      find "$workspace_dir" -name "$pattern" -not -path "*/node_modules/*" -exec cp {} "$output_dir/" \; 2>/dev/null
      local found=$(find "$workspace_dir" -name "$pattern" -not -path "*/node_modules/*" | wc -l)
      artifact_count=$((artifact_count + found))
      log_debug "Collected $found files matching $pattern"
    fi
  done

  log_info "Collected $artifact_count Lighthouse artifacts"

  # List collected artifacts
  if [ "$artifact_count" -gt 0 ]; then
    log_debug "Artifacts collected:"
    ls -la "$output_dir"/ 2>/dev/null | head -10
  fi

  return 0
}

# =============================================================================
# PERFORMANCE ANALYSIS
# =============================================================================

analyze_lighthouse_results() {
  local output_dir="${1:-tmp/artifacts}"
  local threshold_performance="${2:-80}"
  local threshold_accessibility="${3:-90}"

  log_info "Analyzing Lighthouse results..."

  # Look for Lighthouse JSON reports
  local json_reports=$(find "$output_dir" -name "*.json" -type f 2>/dev/null)

  if [ -z "$json_reports" ]; then
    log_warn "No Lighthouse JSON reports found for analysis"
    return 1
  fi

  local analysis_summary=""
  local has_issues=false

  for report in $json_reports; do
    if command -v jq >/dev/null 2>&1; then
      local performance=$(jq -r '.categories.performance.score // "unknown"' "$report" 2>/dev/null)
      local accessibility=$(jq -r '.categories.accessibility.score // "unknown"' "$report" 2>/dev/null)
      local best_practices=$(jq -r '.categories["best-practices"].score // "unknown"' "$report" 2>/dev/null)
      local seo=$(jq -r '.categories.seo.score // "unknown"' "$report" 2>/dev/null)

      # Convert scores to percentages
      if [ "$performance" != "unknown" ] && [ "$performance" != "null" ]; then
        performance=$(echo "$performance * 100" | bc 2>/dev/null | cut -d. -f1)
      fi
      if [ "$accessibility" != "unknown" ] && [ "$accessibility" != "null" ]; then
        accessibility=$(echo "$accessibility * 100" | bc 2>/dev/null | cut -d. -f1)
      fi

      analysis_summary="${analysis_summary}Performance: ${performance}%, Accessibility: ${accessibility}%, Best Practices: ${best_practices}, SEO: ${seo}\n"

      # Check thresholds
      if [ "$performance" != "unknown" ] && [ "$performance" -lt "$threshold_performance" ]; then
        log_warn "Performance score ($performance%) below threshold ($threshold_performance%)"
        has_issues=true
      fi

      if [ "$accessibility" != "unknown" ] && [ "$accessibility" -lt "$threshold_accessibility" ]; then
        log_warn "Accessibility score ($accessibility%) below threshold ($threshold_accessibility%)"
        has_issues=true
      fi
    fi
  done

  log_info "Lighthouse Analysis Summary:"
  echo -e "$analysis_summary" | while read -r line; do
    if [ -n "$line" ]; then
      log_info "  $line"
    fi
  done

  if [ "$has_issues" = true ]; then
    return 1
  else
    return 0
  fi
}