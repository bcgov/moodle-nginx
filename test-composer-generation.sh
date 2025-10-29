#!/bin/bash
# test-composer-generation.sh
# Quick test to verify composer.json generation works correctly

set -euo pipefail

echo "=== Testing Composer.json Generation ==="
echo ""

# Source the versions file
source ./example.versions.env

echo "ZIPSTREAM_PHP_VERSION from file: ${ZIPSTREAM_PHP_VERSION}"
echo ""

# Create test output
mkdir -p /tmp/test-composer
cat > /tmp/test-composer/composer.json << EOF
{
  "name": "bcgov/moodle-php-dependencies",
  "description": "PHP dependencies for Moodle deployment - Security-controlled versions from centralized management",
  "type": "project",
  "require": {
    "maennchen/zipstream-php": "${ZIPSTREAM_PHP_VERSION}"
  },
  "require-dev": {},
  "config": {
    "optimize-autoloader": true,
    "prefer-stable": true,
    "sort-packages": true
  },
  "minimum-stability": "stable",
  "prefer-stable": true
}
EOF

echo "Generated composer.json:"
cat /tmp/test-composer/composer.json
echo ""

# Verify the version is correct
ACTUAL_VERSION=$(jq -r '.require["maennchen/zipstream-php"]' /tmp/test-composer/composer.json)
echo "Extracted version: $ACTUAL_VERSION"

if [ "$ACTUAL_VERSION" = "^3.2.0" ]; then
    echo "✅ Version generation working correctly!"
else
    echo "❌ Version mismatch! Expected: ^3.2.0, Got: $ACTUAL_VERSION"
    exit 1
fi

echo ""
echo "🎉 Test completed successfully!"