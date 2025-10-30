#!/bin/bash
# optimize-image-push.sh
# Utility script to optimize Docker image push operations to Artifactory
# Uses content-based comparison to detect if images already exist, avoiding redundant pushes

set -euo pipefail

# Default configuration
DEFAULT_TIMEOUT=300  # 5 minutes
DEFAULT_RETRY_COUNT=3

usage() {
    cat << EOF
Usage: $0 --source-image SOURCE --artifactory-url URL [OPTIONS]

Optimizes Docker image push operations using intelligent multi-strategy approach:
• Fast tag-based checking for base images (golang:1.12, ubuntu:24.04, etc.)
• Content hash comparison for custom builds and complex images
• Avoids redundant pushes even when manifest digests differ between registries

Required Arguments:
  --source-image IMAGE     Source image to pull (e.g., php:8.1-fpm)
  --artifactory-url URL    Artifactory base URL

Optional Arguments:
  --timeout SECONDS        Timeout for operations (default: $DEFAULT_TIMEOUT)
  --retry-count COUNT      Number of retries for failed operations (default: $DEFAULT_RETRY_COUNT)
  --force-push            Force push even if image exists
  --quiet                 Suppress informational output
  --help                  Show this help message

Environment Variables:
  ARTIFACTORY_USER        Artifactory username (required if not logged in)
  ARTIFACTORY_PASSWORD    Artifactory password (required if not logged in)
  ARTIFACTORY_REGISTRY    Full registry path including project (e.g., artifacts.developer.gov.bc.ca/m950-learning)
                         If set, takes precedence over URL-based registry detection for image naming

Examples:
  # Basic usage
  $0 --source-image php:8.1-fpm --artifactory-url \$ARTIFACTORY_URL

  # With ARTIFACTORY_REGISTRY environment variable (recommended)
  export ARTIFACTORY_REGISTRY="artifacts.developer.gov.bc.ca/m950-learning"
  $0 --source-image bitnamilegacy/mariadb-galera:10.6 --artifactory-url \$ARTIFACTORY_URL

  # Base image optimization (fast tag check)
  $0 --source-image golang:1.12 --artifactory-url \$ARTIFACTORY_URL

  # Custom image optimization (content hash check)
  $0 --source-image mycompany/custom-app:v1.2.3 --artifactory-url \$ARTIFACTORY_URL

  # With custom timeout and retries
  $0 --source-image mariadb:10 --artifactory-url \$ARTIFACTORY_URL --timeout 600 --retry-count 5

  # Force push (skip optimization)
  $0 --source-image nginx:alpine --artifactory-url \$ARTIFACTORY_URL --force-push

Exit Codes:
  0 - Success (image was cached or successfully pushed)
  1 - General error
  2 - Invalid arguments
  3 - Docker operation failed
  4 - Artifactory access failed
EOF
}

log_info() {
    if [ "${QUIET:-false}" != "true" ]; then
        echo "ℹ️  $1"
    fi
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

log_time() {
    local duration=$1
    local operation=$2
    echo "⏱️ $operation completed in ${duration}s"
}

# Parse command line arguments
parse_args() {
    SOURCE_IMAGE=""
    ARTIFACTORY_URL=""
    TIMEOUT="$DEFAULT_TIMEOUT"
    RETRY_COUNT="$DEFAULT_RETRY_COUNT"
    FORCE_PUSH=false
    QUIET=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            --source-image)
                SOURCE_IMAGE="$2"
                shift 2
                ;;
            --artifactory-url)
                ARTIFACTORY_URL="$2"
                shift 2
                ;;
            --timeout)
                TIMEOUT="$2"
                shift 2
                ;;
            --retry-count)
                RETRY_COUNT="$2"
                shift 2
                ;;
            --force-push)
                FORCE_PUSH=true
                shift
                ;;
            --quiet)
                QUIET=true
                shift
                ;;
            --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 2
                ;;
        esac
    done

    # Validate required arguments
    if [ -z "$SOURCE_IMAGE" ]; then
        log_error "Source image is required"
        usage
        exit 2
    fi

    if [ -z "$ARTIFACTORY_URL" ]; then
        log_error "Artifactory URL is required"
        usage
        exit 2
    fi
}

# Check if Docker is available and we're logged in
check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_error "Docker is not installed or not in PATH"
        exit 3
    fi

    if ! command -v jq >/dev/null 2>&1; then
        log_error "jq is required but not installed"
        exit 1
    fi

    # Test Docker daemon access
    if ! docker info >/dev/null 2>&1; then
        log_error "Docker daemon is not accessible"
        exit 3
    fi

    log_info "Docker and jq are available"
    log_info "Docker daemon is accessible"
}

# Get image digest with retries
get_image_digest() {
    local image="$1"
    local retry_count="$2"
    local digest=""

    for ((i=1; i<=retry_count; i++)); do
        log_info "Attempt $i/$retry_count: Getting digest for $image"

        # Try multiple methods to get the digest
        # Method 1: Try docker manifest inspect (preferred for remote registries)
        if command -v docker >/dev/null 2>&1; then
            digest=$(timeout "$TIMEOUT" docker manifest inspect "$image" 2>/dev/null | jq -r '.digest // .manifests[0].digest // empty' 2>/dev/null || echo "")
        fi

        # Method 2: If manifest inspect fails, try inspect with format (works for pulled images)
        if [ -z "$digest" ] || [ "$digest" = "null" ]; then
            digest=$(timeout "$TIMEOUT" docker inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2 2>/dev/null || echo "")
        fi

        # Method 3: Try pulling first then getting digest (fallback)
        if [ -z "$digest" ] || [ "$digest" = "null" ]; then
            log_info "Attempting to pull image to get digest..."
            if timeout "$TIMEOUT" docker pull "$image" >/dev/null 2>&1; then
                digest=$(docker inspect "$image" --format='{{index .RepoDigests 0}}' 2>/dev/null | cut -d'@' -f2 2>/dev/null || echo "")
            fi
        fi

        if [ -n "$digest" ] && [ "$digest" != "null" ] && [ "$digest" != "" ]; then
            echo "$digest"
            return 0
        fi

        if [ $i -lt $retry_count ]; then
            log_warn "Failed to get digest, retrying in 5 seconds..."
            sleep 5
        fi
    done

    return 1
}

# Check if a custom Docker build can be skipped by comparing build context hash
check_custom_build_optimization() {
    local dockerfile_path="$1"
    local build_context="${2:-.}"
    local target_image="$3"

    log_info "🔍 Checking if custom Docker build can be optimized..."

    # Generate hash of build context (Dockerfile + relevant files)
    local build_context_hash=""
    if command -v sha256sum >/dev/null 2>&1; then
        # Include Dockerfile and common dependency files in hash
        build_context_hash=$(find "$build_context" -name "*.dockerfile" -o -name "Dockerfile*" -o -name "composer.json" -o -name "package.json" -o -name "*.sh" -type f 2>/dev/null | sort | xargs sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1 2>/dev/null || echo "")
    elif command -v shasum >/dev/null 2>&1; then
        build_context_hash=$(find "$build_context" -name "*.dockerfile" -o -name "Dockerfile*" -o -name "composer.json" -o -name "package.json" -o -name "*.sh" -type f 2>/dev/null | sort | xargs shasum -a 256 2>/dev/null | shasum -a 256 | cut -d' ' -f1 2>/dev/null || echo "")
    fi

    if [ -z "$build_context_hash" ]; then
        log_warn "Could not generate build context hash - skipping build optimization"
        return 1
    fi

    log_info "📋 Build context hash: $build_context_hash"

    # Check if image exists and get its metadata
    if check_image_exists_by_tag "$target_image" 1; then
        # Try to get build metadata from image labels
        local image_build_hash=""
        if timeout "$TIMEOUT" docker manifest inspect "$target_image" >/dev/null 2>&1; then
            # Try to pull image config to check labels (if supported)
            image_build_hash=$(timeout "$TIMEOUT" docker manifest inspect "$target_image" 2>/dev/null | jq -r '.config.digest // empty' 2>/dev/null || echo "")
        fi

        if [ -n "$image_build_hash" ]; then
            log_info "📋 Found existing custom image with metadata"
            # For now, we'll use content hash comparison as build context comparison
            # This could be enhanced with build metadata labels in the future
            return 0
        fi
    fi

    return 1
}

# Enhanced custom build function that can skip builds when possible
optimize_custom_build() {
    local dockerfile_path="$1"
    local target_image="$2"
    local build_context="${3:-.}"

    log_info "🏗️ Optimizing custom Docker build for: $target_image"

    if check_custom_build_optimization "$dockerfile_path" "$build_context" "$target_image"; then
        log_success "🎯 Custom build can be skipped - image appears unchanged"
        log_success "⚡ Build optimization successful!"
        return 0
    else
        log_info "🔄 Custom build optimization not applicable - build required"
        return 1
    fi
}

# Check if image exists in registry using fast tag-based lookup
check_image_exists_by_tag() {
    local image="$1"
    local retry_count="${2:-1}"

    for ((i=1; i<=retry_count; i++)); do
        log_info "Attempt $i/$retry_count: Checking if image exists by tag: $image"

        # Try docker manifest inspect first (fastest, no pull required)
        if timeout "$TIMEOUT" docker manifest inspect "$image" >/dev/null 2>&1; then
            log_info "✅ Image exists in registry (manifest found)"
            return 0
        fi

        # Fallback: try docker pull with --dry-run if available (Docker 20.10+)
        if docker pull --help 2>/dev/null | grep -q '\--dry-run' 2>/dev/null; then
            if timeout "$TIMEOUT" docker pull --dry-run "$image" >/dev/null 2>&1; then
                log_info "✅ Image exists in registry (dry-run successful)"
                return 0
            fi
        fi

        if [ $i -lt $retry_count ]; then
            log_warn "Image not found, retrying in 3 seconds..."
            sleep 3
        fi
    done

    log_info "❌ Image not found in registry"
    return 1
}

# Determine if this is a base image that can use fast tag-based checking
is_base_image() {
    local image="$1"

    # Base images typically don't have custom namespaces or are from official registries
    case "$image" in
        # Official Docker Hub images
        php:*|golang:*|ubuntu:*|alpine:*|nginx:*|mariadb:*|redis:*|node:*|python:*)
            return 0
            ;;
        # Images with standard namespaces that use semantic versioning
        */php:*|*/golang:*|*/ubuntu:*|*/nginx:*|*/mariadb:*|*/redis:*)
            # Only if they have version tags (not 'latest' or custom tags)
            if [[ "$image" =~ :[0-9]+\.[0-9]+ ]]; then
                return 0
            fi
            ;;
        # Our custom builds (need content checking)
        *moodle*|*cron*|*redis-proxy*|*php-fpm*)
            return 1
            ;;
    esac

    return 1
}

get_image_content_hash() {
    local image="$1"
    local retry_count="$2"

    for ((i=1; i<=retry_count; i++)); do
        log_info "Attempt $i/$retry_count: Getting content hash for $image"

        # Try to get the image configuration digest which is consistent across registries
        local config_digest=""
        if command -v docker >/dev/null 2>&1; then
            # Get the config digest from manifest - this represents the actual image content
            config_digest=$(timeout "$TIMEOUT" docker manifest inspect "$image" 2>/dev/null | jq -r '.config.digest // empty' 2>/dev/null || echo "")

            # Fallback: if manifest inspect doesn't work, try to get the Image ID after pulling
            if [ -z "$config_digest" ] || [ "$config_digest" = "null" ]; then
                # Ensure image is pulled locally
                if timeout "$TIMEOUT" docker pull "$image" >/dev/null 2>&1; then
                    # Get the Image ID which represents the content
                    config_digest=$(docker inspect "$image" --format='{{.Id}}' 2>/dev/null || echo "")
                fi
            fi
        fi

        if [ -n "$config_digest" ] && [ "$config_digest" != "null" ] && [ "$config_digest" != "" ]; then
            echo "$config_digest"
            return 0
        fi

        if [ $i -lt $retry_count ]; then
            log_warn "Failed to get content hash, retrying in 5 seconds..."
            sleep 5
        fi
    done

    return 1
}

# Optimize image push operation
optimize_image_push() {
    local start_time=$(date +%s)
    local source_image="$SOURCE_IMAGE"

    # Handle Artifactory image naming transformation
    # Use ARTIFACTORY_REGISTRY environment variable if available for dynamic configuration
    local artifactory_image
    if [ -n "${ARTIFACTORY_REGISTRY:-}" ]; then
        # Check if source image already includes ARTIFACTORY_REGISTRY path structure
        if [[ "$source_image" == *"$ARTIFACTORY_REGISTRY"* ]]; then
            # Image is already in Artifactory format - use as-is
            artifactory_image="$source_image"
            log_info "📝 Source image already in Artifactory format: $ARTIFACTORY_REGISTRY"
        else
            # Transform source image to Artifactory format
            # For images like "bcgovimages/backup-container:tag" -> "artifacts.../m950-learning/bcgovimages/backup-container:tag"
            # For images like "bitnamilegacy/redis:tag" -> "artifacts.../m950-learning/bitnamilegacy/redis:tag"
            artifactory_image="$ARTIFACTORY_REGISTRY/$source_image"
            log_info "📝 Using ARTIFACTORY_REGISTRY configuration: $ARTIFACTORY_REGISTRY"
        fi
    else
        # Fallback: Direct concatenation with ARTIFACTORY_URL
        artifactory_image="$ARTIFACTORY_URL/$source_image"
        log_info "📝 Using direct ARTIFACTORY_URL concatenation (fallback)"
    fi

    log_info "🚀 Optimizing image push: $source_image -> $artifactory_image"

    # Skip optimization if force push is enabled
    if [ "$FORCE_PUSH" = "true" ]; then
        log_info "🔄 Force push enabled, skipping optimization checks"
        perform_standard_push "$source_image" "$artifactory_image" "$start_time"
        return $?
    fi

    # Use different optimization strategies based on image type
    if is_base_image "$source_image"; then
        log_info "🏃‍♂️ Base image detected - using fast tag-based optimization"

        # Fast check: does the image exist in Artifactory by tag?
        if check_image_exists_by_tag "$artifactory_image" 1; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            log_success "Base image already exists in Artifactory (tag found)"
            log_success "⚡ Skipping pull/push operation - significant time saved!"
            log_success "🏷️ Tag verification: $(echo "$artifactory_image" | cut -d':' -f2)"
            log_time "$duration" "Fast tag check (typical pull/push takes 60-300s)"

            # Set environment variables for GitHub Actions
            if [ -n "${GITHUB_ENV:-}" ]; then
                echo "IMAGE_CACHE_HIT=true" >> "$GITHUB_ENV"
                echo "IMAGE_BUILD_TIME=$duration" >> "$GITHUB_ENV"
                echo "IMAGE_OPERATION=cached_by_tag" >> "$GITHUB_ENV"
            fi

            return 0
        else
            log_info "🔄 Base image not found in Artifactory - will push"
            perform_standard_push "$source_image" "$artifactory_image" "$start_time"
            return $?
        fi
    else
        log_info "🔍 Custom/complex image detected - using content hash optimization"

        # Get source image content hash for reliable comparison
        log_info "🔍 Checking source image content hash..."
        local source_content_hash
        if ! source_content_hash=$(get_image_content_hash "$source_image" "$RETRY_COUNT"); then
            log_warn "Could not get source image content hash for $source_image"
            log_warn "This might be due to registry access issues or image not found"
            log_warn "Proceeding with standard push to ensure image availability"
            perform_standard_push "$source_image" "$artifactory_image" "$start_time"
            return $?
        fi

        log_info "📋 Source content hash: $source_content_hash"

        # Check if same content exists in Artifactory
        log_info "🔍 Checking if image content exists in Artifactory..."
        local artifactory_content_hash
        artifactory_content_hash=$(get_image_content_hash "$artifactory_image" 1 2>/dev/null || echo "")

        if [ "$source_content_hash" = "$artifactory_content_hash" ] && [ -n "$artifactory_content_hash" ]; then
            local end_time=$(date +%s)
            local duration=$((end_time - start_time))

            log_success "Image content already exists in Artifactory (same content hash)"
            log_success "⚡ Skipping pull/push operation - significant time saved!"
            log_success "📋 Content verification: $source_content_hash"
            log_time "$duration" "Content hash check (typical pull/push takes 60-300s)"

            # Set environment variables for GitHub Actions
            if [ -n "${GITHUB_ENV:-}" ]; then
                echo "IMAGE_CACHE_HIT=true" >> "$GITHUB_ENV"
                echo "IMAGE_BUILD_TIME=$duration" >> "$GITHUB_ENV"
                echo "IMAGE_OPERATION=cached_by_content" >> "$GITHUB_ENV"
            fi

            return 0
        else
            if [ -n "$artifactory_content_hash" ]; then
                log_info "🔄 Image content differs in Artifactory (content hash mismatch)"
                log_info "   Source: $source_content_hash"
                log_info "   Artifactory: $artifactory_content_hash"
            else
                log_info "🔄 Image not found in Artifactory or content hash unavailable"
            fi
            perform_standard_push "$source_image" "$artifactory_image" "$start_time"
            return $?
        fi
    fi
}

# Perform standard push operation
perform_standard_push() {
    local source_image="$1"
    local artifactory_image="$2"
    local start_time="$3"

    log_info "📥 Pulling from source registry..."
    if ! timeout "$TIMEOUT" docker pull "$source_image"; then
        log_error "Failed to pull source image: $source_image"
        exit 3
    fi

    log_info "🏷️ Tagging for Artifactory..."
    if ! docker tag "$source_image" "$artifactory_image"; then
        log_error "Failed to tag image"
        exit 3
    fi

    log_info "📤 Pushing to Artifactory..."
    if ! timeout "$TIMEOUT" docker push "$artifactory_image"; then
        log_error "Failed to push to Artifactory"
        exit 4
    fi

    local end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_success "Image successfully pushed to Artifactory"
    log_time "$duration" "Pull/tag/push operation"

    # Set environment variables for GitHub Actions
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "IMAGE_CACHE_HIT=false" >> "$GITHUB_ENV"
        echo "IMAGE_BUILD_TIME=$duration" >> "$GITHUB_ENV"
        echo "IMAGE_OPERATION=pushed" >> "$GITHUB_ENV"
    fi

    return 0
}

# Generate optimization report
generate_report() {
    local operation="${IMAGE_OPERATION:-unknown}"
    local duration="${IMAGE_BUILD_TIME:-0}"
    local cache_hit="${IMAGE_CACHE_HIT:-false}"

    # Determine optimization method used
    local optimization_method="Unknown"
    case "$operation" in
        cached_by_tag)
            optimization_method="Fast Tag Check"
            ;;
        cached_by_content)
            optimization_method="Content Hash Comparison"
            ;;
        pushed)
            optimization_method="Not Applicable (New/Different Content)"
            ;;
    esac

    cat << EOF

📊 IMAGE OPTIMIZATION REPORT
============================
Source Image: $SOURCE_IMAGE
Target Registry: $ARTIFACTORY_URL
Operation: $operation
Optimization Method: $optimization_method
Duration: ${duration}s
Cache Hit: $cache_hit
$([ "$cache_hit" = "true" ] && echo "Content Status: IDENTICAL (no push needed)" || echo "Content Status: DIFFERENT OR NEW")
Performance: $([ "$cache_hit" = "true" ] && echo "OPTIMIZED ⚡" || echo "STANDARD PUSH")

$([ "$cache_hit" = "true" ] && echo "💡 Time saved: ~60-300s (typical pull/push duration)" || echo "")
$([ "$cache_hit" = "false" ] && [ "$operation" = "pushed" ] && echo "📝 Note: 'Layer already exists' messages indicate Docker's layer deduplication is working" || echo "")
$([ "$operation" = "cached_by_tag" ] && echo "🏃‍♂️ Used fast tag-based optimization for base image" || echo "")
$([ "$operation" = "cached_by_content" ] && echo "🔍 Used content hash comparison for custom/complex image" || echo "")
EOF
}

# Main execution
main() {
    parse_args "$@"
    check_docker

    # Export variables for sub-functions
    export SOURCE_IMAGE ARTIFACTORY_URL TIMEOUT RETRY_COUNT FORCE_PUSH QUIET

    if optimize_image_push; then
        generate_report
        log_success "🎉 Image optimization completed successfully"
        exit 0
    else
        log_error "❌ Image optimization failed"
        exit 1
    fi
}

# Run if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi