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
  # All log output goes to stderr to avoid contaminating stdout (used for return values)
  log_info() { echo "ℹ️  $*" >&2; }
  log_warn() { echo "⚠️  $*" >&2; }
  log_error() { echo "❌ $*" >&2; }
  log_debug() {
    if [[ "${DEBUG_LEVEL}" == "DEBUG" ]] || [[ "${DEBUG_LEVEL}" == "TRACE" ]]; then
      echo "🔍 Debug: $*" >&2
    fi
  }
  log_trace() {
    if [[ "${DEBUG_LEVEL}" == "TRACE" ]]; then
      echo "🔬 Trace: $*" >&2
    fi
  }
  log_success() { echo "✅ $*" >&2; }
fi

# =============================================================================
# VERSION INTELLIGENCE & RECOMMENDATIONS
# =============================================================================

# Query Docker Hub/registry for available tags
get_available_tags() {
  local image="$1"
  local max_tags="${2:-50}"  # Limit results for performance

  # Extract registry, repository, and image name
  local registry="docker.io"
  local repo_image="$image"

  # Handle different registry formats
  if [[ "$image" =~ ^([^/]+\.[^/]+)/ ]]; then
    registry="${BASH_REMATCH[1]}"
    repo_image="${image#*/}"
  fi

  log_trace "Querying tags for: $image (registry: $registry)"

  # For Docker Hub images (most common)
  if [[ "$registry" == "docker.io" ]] || [[ "$registry" == "registry.hub.docker.com" ]]; then
    # Docker Hub API v2
    local namespace="library"
    local image_name="$repo_image"

    if [[ "$repo_image" =~ / ]]; then
      namespace="${repo_image%%/*}"
      image_name="${repo_image#*/}"
    fi

    # Query Docker Hub API
    local api_url="https://registry.hub.docker.com/v2/repositories/${namespace}/${image_name}/tags?page_size=${max_tags}"
    local response=$(curl -s "$api_url" 2>/dev/null)

    if [ $? -eq 0 ] && [ -n "$response" ]; then
      # Extract tag names, filter out non-version tags
      echo "$response" | jq -r '.results[].name' 2>/dev/null | grep -E '^[0-9]+\.' | head -n "$max_tags"
      return 0
    fi
  fi

  # Fallback: Try common version patterns
  log_debug "Could not query registry, will try common version patterns"
  return 1
}

# Find upgrade candidates for a given image
find_upgrade_candidates() {
  local current_image="$1"
  local current_version="$2"

  local base_image=$(echo "$current_image" | cut -d: -f1)

  # Parse current version components
  local version_base=$(echo "$current_version" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?' || echo "$current_version")
  local major=$(echo "$version_base" | cut -d. -f1)
  local minor=$(echo "$version_base" | cut -d. -f2)
  local patch=$(echo "$version_base" | cut -d. -f3)
  local suffix=$(echo "$current_version" | sed "s/^${version_base}//")  # e.g., "-alpine", "-fpm"

  log_trace "Parsed version: major=$major, minor=$minor, patch=$patch, suffix=$suffix"

  local candidates=()

  # Strategy 1: Query registry for available versions
  local available_tags=$(get_available_tags "$base_image")

  if [ -n "$available_tags" ]; then
    log_debug "Found available tags from registry"

    # Find newer versions with same suffix
    while IFS= read -r tag; do
      # Match suffix if present
      if [ -n "$suffix" ] && [[ ! "$tag" =~ $suffix ]]; then
        continue
      fi

      # Extract version from tag
      local tag_version=$(echo "$tag" | grep -oE '^[0-9]+\.[0-9]+(\.[0-9]+)?')
      local tag_major=$(echo "$tag_version" | cut -d. -f1)
      local tag_minor=$(echo "$tag_version" | cut -d. -f2)

      # Only consider newer versions within reasonable range (next 2 major/minor versions)
      if [ "$tag_major" -gt "$major" ] && [ "$tag_major" -le $((major + 2)) ]; then
        candidates+=("$tag")
      elif [ "$tag_major" -eq "$major" ] && [ "$tag_minor" -gt "$minor" ] && [ "$tag_minor" -le $((minor + 3)) ]; then
        candidates+=("$tag")
      fi
    done <<< "$available_tags"
  fi

  # Strategy 2: Try common upgrade patterns
  if [ ${#candidates[@]} -eq 0 ]; then
    log_debug "Using common version patterns"

    # Next patch version
    if [ -n "$patch" ] && [ "$patch" != "0" ]; then
      candidates+=("${major}.${minor}.$((patch + 1))${suffix}")
    fi

    # Next minor version
    candidates+=("${major}.$((minor + 1))${suffix}")
    candidates+=("${major}.$((minor + 1)).0${suffix}")

    # Next major version (if reasonable)
    if [ "$major" -lt 10 ]; then
      candidates+=("$((major + 1)).0${suffix}")
    fi
  fi

  # Always include :latest tag for comparison
  candidates+=("latest")

  # Remove duplicates and return
  printf '%s\n' "${candidates[@]}" | sort -u | head -n 5
}

# Scan and compare upgrade candidates
# Returns: Best upgrade candidate or empty if none found
find_best_upgrade() {
  local current_image="$1"
  local severity="${2:-HIGH,CRITICAL}"
  local max_candidates="${3:-5}"

  local base_image=$(echo "$current_image" | cut -d: -f1)
  local current_version=$(echo "$current_image" | cut -d: -f2)

  log_info "   � Analyzing upgrade options for: $current_image"

  # Get current vulnerability baseline
  log_debug "Scanning current image: $current_image"
  local current_scan=$(trivy image --quiet --format json --severity "$severity" "$current_image" 2>&1)

  if [ $? -ne 0 ]; then
    log_warn "      Failed to scan current image, cannot recommend upgrade"
    return 1
  fi

  local current_critical=$(echo "$current_scan" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "999")
  local current_high=$(echo "$current_scan" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "999")

  log_info "      Current: $current_critical critical, $current_high high"

  # Find upgrade candidates
  local candidates=$(find_upgrade_candidates "$current_image" "$current_version")

  if [ -z "$candidates" ]; then
    log_debug "No upgrade candidates found"
    return 1
  fi

  log_debug "Testing upgrade candidates: $(echo "$candidates" | tr '\n' ' ')"

  # Test each candidate and find best option
  local best_candidate=""
  local best_critical="$current_critical"
  local best_high="$current_high"
  local best_score=9999

  while IFS= read -r candidate_tag; do
    if [ -z "$candidate_tag" ]; then
      continue
    fi

    local candidate_image="${base_image}:${candidate_tag}"

    log_trace "Scanning candidate: $candidate_image"

    # Scan candidate (trivy will pull if needed)
    local candidate_scan=$(trivy image --quiet --format json --severity "$severity" "$candidate_image" 2>&1)

    if [ $? -ne 0 ]; then
      log_trace "Failed to scan $candidate_image, skipping"
      continue
    fi

    local candidate_critical=$(echo "$candidate_scan" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "999")
    local candidate_high=$(echo "$candidate_scan" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "999")

    # Calculate score (critical weighted 10x more than high)
    local candidate_score=$((candidate_critical * 10 + candidate_high))
    local current_score=$((current_critical * 10 + current_high))

    log_info "      Testing $candidate_tag: $candidate_critical critical, $candidate_high high"

    # Check if this is better than current AND better than best so far
    if [ "$candidate_score" -lt "$current_score" ] && [ "$candidate_score" -lt "$best_score" ]; then
      best_candidate="$candidate_tag"
      best_critical="$candidate_critical"
      best_high="$candidate_high"
      best_score="$candidate_score"
      log_debug "New best candidate: $candidate_tag (score: $best_score)"
    fi
  done <<< "$candidates"

  # Return best candidate if found
  if [ -n "$best_candidate" ]; then
    local improvement_critical=$((current_critical - best_critical))
    local improvement_high=$((current_high - best_high))

    log_success "      ✅ Recommended: ${base_image}:${best_candidate}"
    log_success "      📊 Improvement: -${improvement_critical} critical, -${improvement_high} high"

    echo "${best_candidate}"
    return 0
  else
    log_info "      ℹ️  No better version found"
    return 1
  fi
}

# Get smart version recommendations based on actual scanning
get_version_recommendation() {
  local image="$1"
  local severity="${2:-HIGH,CRITICAL}"

  local base_image=$(echo "$image" | cut -d: -f1)
  local current_version=$(echo "$image" | cut -d: -f2)

  log_info "   📦 Analyzing: $image"

  # Find best upgrade through scanning
  local best_upgrade=$(find_best_upgrade "$image" "$severity" 5)

  if [ $? -eq 0 ] && [ -n "$best_upgrade" ]; then
    # Format recommendation
    echo "   📦 $base_image"
    echo "      Current: $current_version"
    echo "      Recommended: $best_upgrade"
    echo "      � Validated through security scanning"

    # Add context-specific warnings
    case "$base_image" in
      *"golang"*)
        echo "      ⚠️  Test with your Go modules before upgrading"
        ;;
      *"php"*)
        echo "      ⚠️  Verify Moodle compatibility before upgrading"
        ;;
      *"nginx"*)
        echo "      ⚠️  Review nginx config compatibility"
        ;;
      *"ubuntu"*)
        echo "      ⚠️  Test thoroughly - may require Dockerfile updates"
        ;;
    esac
  else
    # No better version found
    echo "   📦 $base_image:$current_version"
    echo "      ℹ️  No safer version available currently"
    echo "      � Vulnerabilities may require:"
    echo "         • Upstream fixes (wait for base image updates)"
    echo "         • Package updates in Dockerfile (RUN apt-get upgrade)"
    echo "         • Alternative base image (different distro/version)"
  fi
}

# Compare vulnerability counts between two image versions
# Returns: 0 if new version is better/equal, 1 if worse
compare_image_security() {
  local image_a="$1"  # Current image
  local image_b="$2"  # Proposed new image
  local severity="${3:-HIGH,CRITICAL}"

  log_debug "Comparing security: $image_a vs $image_b"

  # Scan current image
  local scan_a=$(trivy image --quiet --format json --severity "$severity" "$image_a" 2>&1)
  local critical_a=$(echo "$scan_a" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "999")
  local high_a=$(echo "$scan_a" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "999")

  # Scan proposed image
  local scan_b=$(trivy image --quiet --format json --severity "$severity" "$image_b" 2>&1)
  local critical_b=$(echo "$scan_b" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "999")
  local high_b=$(echo "$scan_b" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "999")

  log_info "   Security comparison:"
  log_info "      $image_a: $critical_a critical, $high_a high"
  log_info "      $image_b: $critical_b critical, $high_b high"

  # Compare (lower is better)
  if [ "$critical_b" -lt "$critical_a" ] || ([ "$critical_b" -eq "$critical_a" ] && [ "$high_b" -lt "$high_a" ]); then
    log_success "      ✅ Upgrade improves security"
    return 0
  elif [ "$critical_b" -eq "$critical_a" ] && [ "$high_b" -eq "$high_a" ]; then
    log_info "      ℹ️  Similar security profile"
    return 0
  else
    log_warn "      ⚠️  Upgrade has MORE vulnerabilities - investigate before upgrading"
    return 1
  fi
}

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

        # Show top 5 critical vulnerabilities
        log_error "     Top Critical Issues:"
        echo "$scan_output" | jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL") | "       • \(.VulnerabilityID): \(.PkgName) \(.InstalledVersion) → \(.FixedVersion // "no fix available")"' 2>/dev/null | head -5
      fi

      if [ "$high_count" -gt 0 ]; then
        log_warn "  🟡 HIGH: $high_count vulnerabilities"

        # Show top 3 high vulnerabilities if requested
        if [[ "$severity" == *"HIGH"* ]]; then
          log_warn "     Top High Issues:"
          echo "$scan_output" | jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH") | "       • \(.VulnerabilityID): \(.PkgName) \(.InstalledVersion) → \(.FixedVersion // "no fix available")"' 2>/dev/null | head -3
        fi
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

  # Provide version upgrade recommendations if vulnerabilities found
  if [ "$total_critical" -gt 0 ] || [ "$total_high" -gt 0 ]; then
    log_info ""
    log_info "💡 Recommended Actions:"
    log_info ""

    # Generate intelligent upgrade recommendations
    local recommendations_found=false

    for image in "${images_to_scan[@]}"; do
      if [ -z "$image" ]; then
        continue
      fi

      # Check if this specific image has vulnerabilities
      local image_has_vulns=false
      local scan_output
      scan_output=$(trivy image --quiet --format json --severity "$severity" "$image" 2>&1)

      if command -v jq >/dev/null 2>&1; then
        local image_critical=$(echo "$scan_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' 2>/dev/null || echo "0")
        local image_high=$(echo "$scan_output" | jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' 2>/dev/null || echo "0")

        if [ "$image_critical" -gt 0 ] || [ "$image_high" -gt 0 ]; then
          image_has_vulns=true
        fi
      fi

      # Only recommend upgrades for images with vulnerabilities
      if [ "$image_has_vulns" = false ]; then
        continue
      fi

      # Extract base image and version
      local base_image=$(echo "$image" | cut -d: -f1)
      local current_version=$(echo "$image" | cut -d: -f2)

      # Get smart recommendations based on actual current version
      local recommendation=$(get_version_recommendation "$base_image" "$current_version" "$severity")

      if [ -n "$recommendation" ]; then
        recommendations_found=true
        log_info "$recommendation"
        log_info ""
      fi
    done

    if [ "$recommendations_found" = true ]; then
      log_info "   📝 Update these versions in: $versions_file"
      log_info "   🔄 Then re-run scan to validate improvements"
      log_info ""
      log_info "   ⚠️  Note: Always test newer versions for compatibility"
      log_info "   📊 Compare vulnerability counts before/after upgrade"
    else
      log_info "   ℹ️  All images are on recommended versions"
      log_info "   � Vulnerabilities may require upstream fixes"
      log_info "   � Review individual CVEs to assess risk"
    fi
  fi

  # Determine exit code
  if [ "$exit_on_critical" = "true" ] && [ "$total_critical" -gt 0 ]; then
    log_error ""
    log_error "Blocking build due to critical vulnerabilities in base images"
    log_error "   Apply recommended version updates above to resolve"
    return 2
  elif [ "$total_critical" -gt 0 ] || [ "$total_high" -gt 0 ]; then
    log_warn ""
    log_warn "Vulnerabilities detected but allowing build to continue"
    log_warn "   Consider applying recommended updates for improved security"
    return 1
  else
    log_success "All base images passed security scan"
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
    jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL") | "  • \(.VulnerabilityID): \(.PkgName) \(.InstalledVersion) → \(.FixedVersion // "no fix") - \(.Title // "No description")"' "$json_output" 2>/dev/null | head -5 | cut -c1-120
  fi

  # Show top 3 high vulnerabilities if any
  if [ "$high_count" -gt 0 ]; then
    log_warn ""
    log_warn "🟡 Top High Vulnerabilities:"
    jq -r '.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH") | "  • \(.VulnerabilityID): \(.PkgName) \(.InstalledVersion) → \(.FixedVersion // "no fix") - \(.Title // "No description")"' "$json_output" 2>/dev/null | head -3 | cut -c1-120
  fi

  # Determine exit code
  if [ "$exit_on_critical" = "true" ] && [ "$critical_count" -gt 0 ]; then
    log_error ""
    log_error "BLOCKING PUSH: Critical vulnerabilities detected"
    log_error "   Image will NOT be pushed to registry"
    log_error "   Review scan results and fix vulnerabilities before retrying"
    return 2
  elif [ "$critical_count" -gt 0 ] || [ "$high_count" -gt 0 ]; then
    log_warn ""
    log_warn "   Vulnerabilities detected but allowing push"
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
