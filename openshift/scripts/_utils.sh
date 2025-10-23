#!/bin/bash

# =============================================================================
# MODULAR UTILITY LOADER - OPENSHIFT SCRIPTS
# =============================================================================
# This file serves as the main entry point for the deployment utilities.
#
# Module Structure:
# - utils/openshift.sh: Core OpenShift operations (resource management, maintenance, secrets)
# - utils/redis.sh: Redis-specific operations (services, proxy, scaling)
# - utils/database.sh: Galera/MariaDB operations (health checks, auto-healing)
# - utils/moodle.sh: Moodle-specific operations (courses, cache, content)
# =============================================================================

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UTILS_DIR="$SCRIPT_DIR/utils"

# Global variables for backward compatibility
timestamp_file='/var/www/html/last_migration_timestamp'

# =============================================================================
# CORE MODULE LOADING
# =============================================================================

# Load core OpenShift utilities (main include file)
if [[ -f "$UTILS_DIR/openshift.sh" ]]; then
  source "$UTILS_DIR/openshift.sh"
  echo "✅ Loaded OpenShift utilities module"
else
  echo "❌ Warning: OpenShift utilities module not found at $UTILS_DIR/openshift.sh"
  echo "   Falling back to legacy mode..."
fi

# Load Redis-specific utilities
if [[ -f "$UTILS_DIR/redis.sh" ]]; then
  source "$UTILS_DIR/redis.sh"
  echo "✅ Loaded Redis utilities module"
else
  echo "⚠️ Warning: Redis utilities module not found at $UTILS_DIR/redis.sh"
fi

# Load Database utilities
if [[ -f "$UTILS_DIR/database.sh" ]]; then
  source "$UTILS_DIR/database.sh"
  echo "✅ Loaded Database utilities module"
else
  echo "⚠️ Warning: Database utilities module not found at $UTILS_DIR/database.sh"
fi

# Load Moodle utilities
if [[ -f "$UTILS_DIR/moodle.sh" ]]; then
  source "$UTILS_DIR/moodle.sh"
  echo "✅ Loaded Moodle utilities module"
else
  echo "⚠️ Warning: Moodle utilities module not found at $UTILS_DIR/moodle.sh"
fi
