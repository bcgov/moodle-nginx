#!/bin/bash
# Docker Image Security Scanning Utilities
# Scans Docker images for vulnerabilities before pushing to registries

# Get the directory where this script is located
_DOCKER_SECURITY_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source the core OpenShift utilities for logging functions
if [[ -f "$_DOCKER_SECURITY_SCRIPT_DIR/openshift.sh" ]]; then
  source "$_DOCKER_SECURITY_SCRIPT_DIR/openshift.sh"
else
  # Fallback: Define minimal logging functions if openshift.sh not found
  log_info() { echo "ℹ️  $*"; }
  log_warn() { echo "⚠️  $*"; }
  log_error() { echo "❌ $*"; }
  log_debug() { echo "🔍 Debug: $*"; }
  log_success() { echo "✅ $*"; }
fi

# =============================================================================
# PUBLIC BASE IMAGE SCANNING
# =============================================================================

scan_public_base_images() {
  local versions_file="${1:-example.versions.env}"
  local severity="${2:-HIGH,CRITICAL}"
  local exit_on_critical="${3:-true}"

  log_info "🔍 Scanning public base images for vulnerabilities..."

  if [ ! -f "$versions_file" ]; then
    log_error "Versions file not found: $versions_file"
    return 1
  fi

  # Source environment variables
  set -a
  source "$versions_file"
  set +a

  local images_to_scan=(
    "$PHP_IMAGE"
    "$CRON_IMAGE"
    "$WEB_IMAGE"
    "$GOLANG_IMAGE"
    "$UBUNTU_IMAGE"
  )

  local total_critical=0
  local total_high=0
  local failed_scans=0

  for image in "${images_to_scan[@]}"; do
    if [ -z "$image" ]; then
      log_debug "Skipping empty image reference"
      continue
    fi

    log_info "Scanning: $image"

    # Run Trivy scan with JSON output
    local scan_output
    scan_output=$(trivy image \
      --quiet \
      --format json \
      --severity "$severity" \
      "$image" 2>&1)

    local scan_exit=$?

    if [ $scan_exit -ne 0 ]; then
      log_error "Failed to scan $image"
      failed_scans=$((failed_scans + 1))
      continue
    fi

    # Parse results
    if command -v jq >/dev/null 2>&1; then
      local critical_count=$(echo "$scan_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "0")
      local high_count=$(echo "$scan_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "0")

      total_critical=$((total_critical + critical_count))
      total_high=$((total_high + high_count))

      if [ "$critical_count" -gt 0 ]; then
        log_error "  🔴 CRITICAL: $critical_count vulnerabilities"
      fi

      if [ "$high_count" -gt 0 ]; then
        log_warn "  🟡 HIGH: $high_count vulnerabilities"
      fi

      if [ "$critical_count" -eq 0 ] && [ "$high_count" -eq 0 ]; then
        log_success "  ✅ No $severity vulnerabilities found"
      fi
    fi
  done

  # Summary
  log_info ""
  log_info "📊 Public Base Image Scan Summary:"
  log_info "  Images scanned: ${#images_to_scan[@]}"
  log_info "  Critical vulnerabilities: $total_critical"
  log_info "  High vulnerabilities: $total_high"
  log_info "  Failed scans: $failed_scans"

  # Determine exit code
  if [ "$exit_on_critical" = "true" ] && [ "$total_critical" -gt 0 ]; then
    log_error "❌ Blocking build due to critical vulnerabilities in base images"
    log_error "   Review vulnerabilities and update base image versions in $versions_file"
    return 2
  elif [ "$total_critical" -gt 0 ] || [ "$total_high" -gt 0 ]; then
    log_warn "⚠️  Vulnerabilities detected but allowing build to continue"
    return 1
  else
    log_success "✅ All base images passed security scan"
    return 0
  fi
}

# =============================================================================
# BUILT IMAGE SCANNING (Post-Build, Pre-Push)
# =============================================================================

scan_built_image() {
  local image_tag="$1"
  local severity="${2:-HIGH,CRITICAL}"
  local exit_on_critical="${3:-true}"
  local output_file="${4:-}"

  log_info "🔍 Scanning built image: $image_tag"

  if [ -z "$image_tag" ]; then
    log_error "Image tag is required"
    return 1
  fi

  # Check if image exists locally
  if ! docker image inspect "$image_tag" >/dev/null 2>&1; then
    log_error "Image not found locally: $image_tag"
    log_error "Build the image first before scanning"
    return 1
  fi

  # Prepare output file
  local json_output="/tmp/trivy-scan-$(date +%s).json"
  if [ -n "$output_file" ]; then
    json_output="$output_file"
    mkdir -p "$(dirname "$json_output")"
  fi

  # Run Trivy scan
  log_debug "Running Trivy scan with severity: $severity"

  trivy image \
    --format json \
    --output "$json_output" \
    --severity "$severity" \
    "$image_tag"

  local scan_exit=$?

  if [ $scan_exit -ne 0 ]; then
    log_error "Trivy scan failed with exit code: $scan_exit"
    return 1
  fi

  # Parse results
  if [ ! -f "$json_output" ] || ! command -v jq >/dev/null 2>&1; then
    log_warn "Cannot parse scan results (missing jq or output file)"
    return 0
  fi

  local critical_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$json_output" 2>/dev/null || echo "0")
  local high_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$json_output" 2>/dev/null || echo "0")
  local medium_count=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="MEDIUM")] | length' "$json_output" 2>/dev/null || echo "0")

  # Display results
  log_info ""
  log_info "📊 Vulnerability Summary for: $image_tag"
  log_info "  🔴 CRITICAL: $critical_count"
  log_info "  🟡 HIGH: $high_count"
  log_info "  🟠 MEDIUM: $medium_count"
  log_info "  📄 Full report: $json_output"

  # Show top 5 critical vulnerabilities if any
  if [ "$critical_count" -gt 0 ]; then
    log_error ""
    log_error "🔴 Top Critical Vulnerabilities:"
    jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL") | "  • \(.VulnerabilityID): \(.PkgName) \(.InstalledVersion) - \(.Title // "No description")[:80]"' "$json_output" 2>/dev/null | head -5
  fi

  # Determine exit code
  if [ "$exit_on_critical" = "true" ] && [ "$critical_count" -gt 0 ]; then
    log_error ""
    log_error "❌ BLOCKING PUSH: Critical vulnerabilities detected"
    log_error "   Image will NOT be pushed to registry"
    log_error "   Review scan results and fix vulnerabilities before retrying"
    return 2
  elif [ "$critical_count" -gt 0 ] || [ "$high_count" -gt 0 ]; then
    log_warn ""
    log_warn "⚠️  Vulnerabilities detected but allowing push"
    log_warn "   Consider reviewing and fixing these issues"
    return 1
  else
    log_success ""
    log_success "✅ Image passed security scan - safe to push"
    return 0
  fi
}

# =============================================================================
# WORKFLOW INTEGRATION HELPERS
# =============================================================================

# GitHub Actions step: Scan image after build
# Usage in workflow:
#   - name: 🔒 Security Scan Built Image
#     run: |
#       source openshift/scripts/utils/docker-security.sh
#       scan_built_image_for_github_actions \
#         "${{ secrets.ARTIFACTORY_URL }}/${{ env.PHP_DEPLOYMENT_NAME }}:${{ github.ref_name }}" \
#         "CRITICAL,HIGH" \
#         "true"
scan_built_image_for_github_actions() {
  local image_tag="$1"
  local severity="${2:-HIGH,CRITICAL}"
  local exit_on_critical="${3:-true}"

  log_info "🔒 Post-Build Security Scan"
  log_info "Image: $image_tag"
  log_info "Severity threshold: $severity"
  log_info "Block on critical: $exit_on_critical"
  echo ""

  # Create artifacts directory
  mkdir -p tmp/security-scans
  local output_file="tmp/security-scans/$(basename "$image_tag" | tr ':/' '__').json"

  # Run scan
  scan_built_image "$image_tag" "$severity" "$exit_on_critical" "$output_file"
  local scan_result=$?

  # Add to GitHub Actions summary if available
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "## 🔒 Security Scan: $image_tag"
      echo ""

      if command -v jq >/dev/null 2>&1 && [ -f "$output_file" ]; then
        local critical=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$output_file" 2>/dev/null || echo "0")
        local high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$output_file" 2>/dev/null || echo "0")

        echo "| Severity | Count |"
        echo "|----------|-------|"
        echo "| 🔴 CRITICAL | $critical |"
        echo "| 🟡 HIGH | $high |"
        echo ""

        if [ "$scan_result" -eq 2 ]; then
          echo "❌ **SCAN FAILED** - Critical vulnerabilities detected, push blocked"
        elif [ "$scan_result" -eq 1 ]; then
          echo "⚠️  **VULNERABILITIES DETECTED** - Review recommended but push allowed"
        else
          echo "✅ **SCAN PASSED** - No critical vulnerabilities"
        fi
      fi
    } >> "$GITHUB_STEP_SUMMARY"
  fi

  return $scan_result
}

# Export functions for use in workflows
export -f scan_public_base_images
export -f scan_built_image
export -f scan_built_image_for_github_actions
