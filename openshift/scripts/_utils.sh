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

# Set default debug level if not provided
DEBUG_LEVEL="${DEBUG_LEVEL:-INFO}"

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Function to log debug messages only when DEBUG_LEVEL is set to DEBUG
log_debug() {
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    echo "🔍 Debug: $*"
  fi
}

# Function to log info messages (always shown)
log_info() {
  echo "ℹ️  $*"
}

# Function to log warning messages (always shown)
log_warn() {
  echo "⚠️  $*"
}

# Function to log error messages (always shown)
log_error() {
  echo "❌ $*"
}

# Function to log success messages (always shown)
log_success() {
  echo "✅ $*"
}

# =============================================================================
# CORE MODULE LOADING
# =============================================================================

# Load core OpenShift utilities (main include file)
if [[ -f "$UTILS_DIR/openshift.sh" ]]; then
  source "$UTILS_DIR/openshift.sh"
  log_debug "Loaded OpenShift utilities module"
else
  log_error "Warning: OpenShift utilities module not found at $UTILS_DIR/openshift.sh"
  echo "   Falling back to legacy mode..."
fi

# Load Redis-specific utilities
if [[ -f "$UTILS_DIR/redis.sh" ]]; then
  source "$UTILS_DIR/redis.sh"
  log_debug "Loaded Redis utilities module"
else
  log_warn "Warning: Redis utilities module not found at $UTILS_DIR/redis.sh"
fi

# Load Database utilities
if [[ -f "$UTILS_DIR/database.sh" ]]; then
  source "$UTILS_DIR/database.sh"
  log_debug "Loaded Database utilities module"
else
  log_warn "Warning: Database utilities module not found at $UTILS_DIR/database.sh"
fi

# Load Moodle utilities
if [[ -f "$UTILS_DIR/moodle.sh" ]]; then
  source "$UTILS_DIR/moodle.sh"
  log_debug "Loaded Moodle utilities module"
else
  log_warn "Warning: Moodle utilities module not found at $UTILS_DIR/moodle.sh"
fi
