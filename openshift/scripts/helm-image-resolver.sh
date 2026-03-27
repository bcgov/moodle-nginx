#!/bin/bash
#==============================================================================
# helm-image-resolver.sh
#==============================================================================
# PURPOSE:
#   Utility functions for resolving Helm chart container images with support
#   for both public registries (Docker Hub, GCR, Quay) and private Artifactory
#   registry. Provides DRY image management across all deployment scripts.
#
# FUNCTIONS:
#   resolve_helm_image()        - Resolve full image URL from environment variable
#   validate_helm_environment() - Validate required Helm/registry environment variables
#   show_artifactory_status()   - Display current registry configuration
#
# ARCHITECTURE:
#   - Reads image definitions from environment (e.g., MARIADB_IMAGE, REDIS_IMAGE)
#   - Strips public registry prefixes when using Artifactory (docker.io/*, gcr.io/*, quay.io/*)
#   - Concatenates appropriate registry prefix based on USE_ARTIFACTORY setting
#   - Exports RESOLVED_* variables for consumption by deployment scripts
#
# ARTIFACTORY MODE:
#   When USE_ARTIFACTORY=true:
#   - Strips external registry prefixes from image names
#   - Prepends ARTIFACTORY_REGISTRY to create full image path
#   - Example: docker.io/bitnami/mariadb:11.0.3 → artifactory.example.com/bitnami/mariadb:11.0.3
#
# PUBLIC REGISTRY MODE:
#   When USE_ARTIFACTORY=false:
#   - Uses HELM_REPO as registry (typically empty for Docker Hub)
#   - Preserves full image path as-is
#   - Example: bitnami/mariadb:11.0.3 → bitnami/mariadb:11.0.3
#
# EXPORTED VARIABLES:
#   RESOLVED_IMAGE_REGISTRY      - Registry hostname (with or without Artifactory)
#   RESOLVED_IMAGE_REPOSITORY    - Repository path (e.g., bitnami/mariadb)
#   RESOLVED_IMAGE_TAG           - Image tag (e.g., 11.0.3)
#   RESOLVED_FULL_IMAGE          - Complete image URL
#
# USAGE:
#   # Source this file in deployment scripts
#   source ./openshift/scripts/helm-image-resolver.sh
#
#   # Resolve MariaDB image
#   if ! resolve_helm_image "MARIADB_IMAGE"; then
#       echo "Failed to resolve image"
#       exit 1
#   fi
#   echo "Using: ${RESOLVED_FULL_IMAGE}"
#
# RELATED FILES:
#   - Environment: ./example.versions.env
#   - Deployments: ./deploy-mariadb-galera.sh, ./deploy-redis-sentinel.sh
#==============================================================================

# Function to resolve full image URL by concatenating registry and image
# Usage: resolve_helm_image "MARIADB_IMAGE"
# Returns: full image URL based on USE_ARTIFACTORY setting
resolve_helm_image() {
    local image_var="$1"  # e.g., "MARIADB_IMAGE", "REDIS_IMAGE"

    # Get image name:tag from environment variable
    local image_name_tag="${!image_var}"

    if [ -z "$image_name_tag" ]; then
        echo "❌ Error: ${image_var} not defined in environment" >&2
        echo "   Available environment variables starting with image-related names:" >&2
        env | grep -i "IMAGE\|REGISTRY\|REPO" | head -10 >&2 || echo "   (no matching environment variables found)" >&2
        echo "   💡 Make sure to source example.versions.env before calling this function" >&2
        return 1
    fi

    # Strip any existing registry prefix from image_name_tag ONLY if using Artifactory
    local image_path="$image_name_tag"
    if [ "${USE_ARTIFACTORY:-false}" = "true" ]; then
        if [[ "$image_path" == registry-1.docker.io/* ]]; then
            image_path="${image_path#registry-1.docker.io/}"
            echo "📝 Stripped registry-1.docker.io prefix: $image_path" >&2
        elif [[ "$image_path" == docker.io/* ]]; then
            image_path="${image_path#docker.io/}"
            echo "📝 Stripped docker.io prefix: $image_path" >&2
        elif [[ "$image_path" == gcr.io/* ]] || [[ "$image_path" == quay.io/* ]]; then
            image_path="${image_path#*/}"
            echo "📝 Stripped external registry prefix: $image_path" >&2
        fi
    fi

    # Choose registry based on USE_ARTIFACTORY setting
    local registry
    if [ "${USE_ARTIFACTORY:-false}" = "true" ]; then
        if [ -z "$ARTIFACTORY_REGISTRY" ]; then
            echo "❌ Error: USE_ARTIFACTORY=true but ARTIFACTORY_REGISTRY not defined" >&2
            echo "   💡 Set ARTIFACTORY_REGISTRY or set USE_ARTIFACTORY=false" >&2
            return 1
        fi
        registry="$ARTIFACTORY_REGISTRY"
    else
        if [ -z "$HELM_REPO" ]; then
            echo "❌ Error: HELM_REPO not defined in environment" >&2
            echo "   💡 Make sure to source example.versions.env before calling this function" >&2
            return 1
        fi
        registry="$HELM_REPO"
    fi

    # Construct full image URL
    local full_image="${registry}/${image_path}"

    # Extract repository and tag for Helm --set commands
    local repository="${full_image%:*}"  # Everything before the last ':'
    local tag="${full_image##*:}"        # Everything after the last ':'

    # Determine image.registry value based on Artifactory usage
    # Bitnami charts construct images as: {image.registry}/{image.repository}:{image.tag}
    # When using Artifactory, we include full path in repository and set registry to empty
    # When using upstream, we let the chart use its default registry (docker.io)
    local image_registry=""
    if [ "${USE_ARTIFACTORY:-false}" = "true" ]; then
        # For Artifactory: registry is empty, repository contains full path
        image_registry=""
        # Repository already contains full path including Artifactory registry
    else
        # For upstream: let Helm chart use its default registry (docker.io for Bitnami)
        # We don't set registry, so chart defaults will apply
        image_registry="docker.io"
        # Strip any registry prefix from repository since chart will add it
        if [[ "$repository" == */docker.io/* ]]; then
            repository="${repository/docker.io\//}"
            echo "📝 Stripped docker.io prefix from repository: $repository" >&2
        elif [[ "$repository" == */registry-1.docker.io/* ]]; then
            repository="${repository/registry-1.docker.io\//}"
            echo "📝 Stripped registry-1.docker.io prefix from repository: $repository" >&2
        fi
    fi

    # Export variables for the calling script
    export RESOLVED_IMAGE_REGISTRY="$image_registry"
    export RESOLVED_IMAGE_REPOSITORY="$repository"
    export RESOLVED_IMAGE_TAG="$tag"
    export RESOLVED_FULL_IMAGE="$full_image"

    echo "🔧 Resolved ${image_var}: ${full_image}"
    echo "   Registry: ${image_registry:-<chart-default>}"
    echo "   Repository: $repository"
    echo "   Tag: $tag"
    return 0
}

# Function to get Helm set arguments for image configuration
# Usage: get_helm_image_args "MARIADB_IMAGE"
# Returns: --set arguments ready for helm install/upgrade
get_helm_image_args() {
    local image_var="$1"
    local registry_prefix="${2:-image}"  # default: "image", could be "sentinel.image" for Redis

    if ! resolve_helm_image "$image_var"; then
        return 1
    fi

    echo "--set ${registry_prefix}.registry=${RESOLVED_IMAGE_REGISTRY} --set ${registry_prefix}.repository=${RESOLVED_IMAGE_REPOSITORY} --set ${registry_prefix}.tag=${RESOLVED_IMAGE_TAG}"
}

# Function to validate that all required Helm images are defined
validate_helm_environment() {
    local images=("MARIADB_IMAGE" "REDIS_IMAGE" "REDIS_SENTINEL_IMAGE")
    local all_valid=true

    echo "🔍 Validating Helm image environment variables..."
    echo "📋 Environment Status:"
    echo "   USE_ARTIFACTORY: ${USE_ARTIFACTORY:-NOT_SET}"
    echo "   HELM_REPO: ${HELM_REPO:-NOT_SET}"
    echo "   ARTIFACTORY_REGISTRY: ${ARTIFACTORY_REGISTRY:-NOT_SET}"
    echo ""

    # Show debug info for the specific images we're using
    echo "📋 Raw Image Variables:"
    for image in "${images[@]}"; do
        local image_value="${!image}"
        echo "   $image: ${image_value:-NOT_SET}"
    done
    echo ""

    echo "📋 Resolved Image Configurations:"
    for image in "${images[@]}"; do
        local image_value="${!image}"
        if [ -n "$image_value" ]; then
            # Capture resolution output for debugging
            if resolve_helm_image "$image" 2>/dev/null; then
                echo "✅ $image: ${RESOLVED_FULL_IMAGE}"
                echo "   → Repository: ${RESOLVED_IMAGE_REPOSITORY}"
                echo "   → Tag: ${RESOLVED_IMAGE_TAG}"
            else
                echo "❌ $image: Resolution failed (${image_value})"
                echo "   → Debugging resolution..."
                resolve_helm_image "$image"  # Show errors
                all_valid=false
            fi
        else
            echo "❌ $image: NOT_SET"
            all_valid=false
        fi
    done

    echo ""
    if [ "$all_valid" = "true" ]; then
        echo "✅ All Helm image configurations are valid"
        return 0
    else
        echo "❌ Some Helm image configurations are invalid"
        echo "💡 Troubleshooting steps:"
        echo "   1. Make sure you've sourced example.versions.env"
        echo "   2. Check that all required variables are set in example.versions.env"
        echo "   3. Verify HELM_REPO and ARTIFACTORY_REGISTRY are properly configured"
        return 1
    fi
}

# Function to show current Artifactory status
show_artifactory_status() {
    echo "🏭 Registry Configuration:"
    echo "   HELM_REPO: ${HELM_REPO:-NOT_SET}"
    echo "   ARTIFACTORY_REGISTRY: ${ARTIFACTORY_REGISTRY:-NOT_SET}"
    echo "   USE_ARTIFACTORY: ${USE_ARTIFACTORY:-false}"
    echo ""

    if [ "${USE_ARTIFACTORY:-false}" = "true" ]; then
        echo "   📦 Images will be pulled from: ${ARTIFACTORY_REGISTRY:-NOT_SET}"
        echo "   🎯 Mode: ARTIFACTORY (supply chain protected)"
    else
        echo "   📦 Images will be pulled from: ${HELM_REPO:-NOT_SET}"
        echo "   🎯 Mode: UPSTREAM (bitnami legacy)"
        echo "   💡 Set USE_ARTIFACTORY=true to enable Artifactory"
    fi
}

# Example usage function
example_usage() {
    cat << 'EOF'
# Example usage in deploy-mariadb-galera.sh:

# Source the utility
source ./openshift/scripts/helm-image-resolver.sh

# Validate environment
if ! validate_helm_environment; then
    exit 1
fi

# Show current status
show_artifactory_status

# Get MariaDB image arguments
MARIADB_IMAGE_ARGS=$(get_helm_image_args "MARIADB_IMAGE")

# Use in Helm commands
helm install $DB_DEPLOYMENT_NAME \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
    $MARIADB_IMAGE_ARGS \
    --set global.security.allowInsecureImages=true \
    # ... other settings

# Or manually if you need more control:
resolve_helm_image "MARIADB_IMAGE"
helm install $DB_DEPLOYMENT_NAME \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
    --set image.repository=$RESOLVED_IMAGE_REPOSITORY \
    --set image.tag=$RESOLVED_IMAGE_TAG \
    # ... other settings

# Results in:
# USE_ARTIFACTORY=false: registry-1.docker.io/bitnamilegacy/mariadb-galera:10.6
# USE_ARTIFACTORY=true:  artifacts.developer.gov.bc.ca/m950-learning/mariadb-galera:10.6
EOF
}

# If script is called with --example, show usage
if [ "$1" = "--example" ]; then
    example_usage
fi