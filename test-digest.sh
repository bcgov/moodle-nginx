#!/bin/bash
# Test script for the get_image_digest function

# Source the optimize script to use its functions
source ./openshift/scripts/optimize-image-push.sh

# Test with a common image
TEST_IMAGE="alpine:latest"
echo "Testing digest function with: $TEST_IMAGE"

# Set required environment variables
TIMEOUT=300
QUIET=false

# Test the function
if digest=$(get_image_digest "$TEST_IMAGE" 3); then
    echo "✅ Success! Digest: $digest"
else
    echo "❌ Failed to get digest"
fi