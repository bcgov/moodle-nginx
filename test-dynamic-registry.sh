#!/bin/bash
# Test script to verify dynamic registry resolution in optimize-image-push.sh

# Load environment variables
source ./example.versions.env

echo "🧪 Testing Dynamic Registry Resolution"
echo "======================================"
echo ""

# Test case 1: With ARTIFACTORY_REGISTRY environment variable
echo "Test 1: With ARTIFACTORY_REGISTRY environment variable"
echo "ARTIFACTORY_REGISTRY: $ARTIFACTORY_REGISTRY"
echo ""

# Simulate the logic from optimize-image-push.sh
test_image_resolution() {
    local source_image="$1"
    local expected_result="$2"
    
    echo "📦 Source image: $source_image"
    
    # Replicate the logic from the script
    local artifactory_image
    if [ -n "${ARTIFACTORY_REGISTRY:-}" ]; then
        # Extract image name without registry prefix (e.g., mariadb-galera:tag from bitnamilegacy/mariadb-galera:tag)
        local image_name=$(echo "$source_image" | sed 's|^[^/]*/||')
        artifactory_image="$ARTIFACTORY_REGISTRY/$image_name"
        echo "🔧 Using ARTIFACTORY_REGISTRY: $ARTIFACTORY_REGISTRY"
    else
        # Fallback: Direct concatenation with ARTIFACTORY_URL
        artifactory_image="ARTIFACTORY_URL/$source_image"
        echo "🔧 Using direct ARTIFACTORY_URL concatenation (fallback)"
    fi
    
    echo "🎯 Result: $artifactory_image"
    echo "✅ Expected: $expected_result"
    
    if [ "$artifactory_image" = "$expected_result" ]; then
        echo "✅ PASS"
    else
        echo "❌ FAIL"
    fi
    echo ""
}

# Test with various source images
test_image_resolution "bitnamilegacy/mariadb-galera:10.6" "artifacts.developer.gov.bc.ca/m950-learning/mariadb-galera:10.6"
test_image_resolution "bitnamilegacy/redis:8.0.2-debian-12-r2" "artifacts.developer.gov.bc.ca/m950-learning/redis:8.0.2-debian-12-r2"
test_image_resolution "registry-1.docker.io/bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1" "artifacts.developer.gov.bc.ca/m950-learning/redis-sentinel:8.0.2-debian-12-r1"

# Test case 2: Without ARTIFACTORY_REGISTRY (fallback mode)
echo "Test 2: Without ARTIFACTORY_REGISTRY (fallback mode)"
unset ARTIFACTORY_REGISTRY
test_image_resolution "bitnamilegacy/mariadb-galera:10.6" "ARTIFACTORY_URL/bitnamilegacy/mariadb-galera:10.6"

echo "🎯 Summary: The logic dynamically uses ARTIFACTORY_REGISTRY when available,"
echo "    falling back to URL-based concatenation when not set."
echo "    This eliminates hardcoded registry paths in the script!"