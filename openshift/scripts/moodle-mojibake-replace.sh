#!/bin/bash

# Ensure the script is running with bash
if [ -z "$BASH_VERSION" ]; then
  echo "This script must be run with bash. Switching to bash..."
  exec /bin/bash "$0" "$@"
fi

# Source the utility script
source /usr/local/bin/_utils.sh

echo "Starting Mojibake Replacement..."

cd /

echo "Searching for encoding issues in content tables..."
moodle_content_cleanup find
# echo "Replace improperly encoded characters in content tables"
# moodle_content_cleanup replace
