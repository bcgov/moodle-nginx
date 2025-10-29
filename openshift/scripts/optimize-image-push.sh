#!/bin/bash
# optimize-image-push.sh
# Utility script to optimize Docker image push operations to Artifactory
# Checks if images already exist before pulling/pushing to save build time

set -euo pipefail

# Default configuration
DEFAULT_TIMEOUT=300  # 5 minutes
DEFAULT_RETRY_COUNT=3

usage() {
    cat << EOF
Usage: $0 --source-image SOURCE --artifactory-url URL [OPTIONS]

Optimizes Docker image push operations by checking if images already exist in Artifactory.

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

Examples:
  # Basic usage
  $0 --source-image php:8.1-fpm --artifactory-url \$ARTIFACTORY_URL

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

# Optimize image push operation
optimize_image_push() {
    local start_time=$(date +%s)
    local source_image="$SOURCE_IMAGE"
    local artifactory_image="$ARTIFACTORY_URL/$source_image"

    log_info "🚀 Optimizing image push: $source_image -> $artifactory_image"

    # Skip optimization if force push is enabled
    if [ "$FORCE_PUSH" = "true" ]; then
        log_info "🔄 Force push enabled, skipping optimization checks"
        perform_standard_push "$source_image" "$artifactory_image" "$start_time"
        return $?
    fi

    # Get source image digest
    log_info "🔍 Checking source image digest..."
    local source_digest
    if ! source_digest=$(get_image_digest "$source_image" "$RETRY_COUNT"); then
        log_warn "Could not get source image digest for $source_image"
        log_warn "This might be due to registry access issues or image not found"
        log_warn "Proceeding with standard push to ensure image availability"
        perform_standard_push "$source_image" "$artifactory_image" "$start_time"
        return $?
    fi

    log_info "📋 Source digest: $source_digest"

    # Check if same digest exists in Artifactory
    log_info "🔍 Checking if image exists in Artifactory..."
    local artifactory_digest
    artifactory_digest=$(get_image_digest "$artifactory_image" 1 || echo "")

    if [ "$source_digest" = "$artifactory_digest" ] && [ -n "$artifactory_digest" ]; then
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))

        log_success "Image already exists in Artifactory with same digest"
        log_success "⚡ Skipping pull/push operation - significant time saved!"
        log_time "$duration" "Optimization check (typical pull/push takes 60-300s)"

        # Set environment variables for GitHub Actions
        if [ -n "${GITHUB_ENV:-}" ]; then
            echo "IMAGE_CACHE_HIT=true" >> "$GITHUB_ENV"
            echo "IMAGE_BUILD_TIME=$duration" >> "$GITHUB_ENV"
            echo "IMAGE_OPERATION=cached" >> "$GITHUB_ENV"
        fi

        return 0
    else
        log_info "🔄 Image needs to be updated in Artifactory"
        perform_standard_push "$source_image" "$artifactory_image" "$start_time"
        return $?
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

    cat << EOF

📊 IMAGE OPTIMIZATION REPORT
============================
Source Image: $SOURCE_IMAGE
Target Registry: $ARTIFACTORY_URL
Operation: $operation
Duration: ${duration}s
Cache Hit: $cache_hit
Optimization: $([ "$cache_hit" = "true" ] && echo "ENABLED ⚡" || echo "NOT APPLICABLE")

$([ "$cache_hit" = "true" ] && echo "💡 Time saved: ~60-300s (typical pull/push duration)" || echo "")
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