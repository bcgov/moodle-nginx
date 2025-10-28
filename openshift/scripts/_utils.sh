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

# Set default cluster health monitoring if not provided
CLUSTER_HEALTH_MONITORING="${CLUSTER_HEALTH_MONITORING:-YES}"

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

# =============================================================================
# UTILITY FILE MANAGEMENT FOR CONFIGMAPS
# =============================================================================

# Generate the list of all utility files for deployment consistency
# This ensures that any script using _utils.sh in containers has access to all modules
get_utility_files() {
  local base_dir="${1:-./openshift/scripts}"
  local files=("$base_dir/_utils.sh")

  # Dynamically discover all utility modules
  if [[ -d "$base_dir/utils" ]]; then
    while IFS= read -r -d '' file; do
      files+=("$file")
    done < <(find "$base_dir/utils" -name "*.sh" -type f -print0 | sort -z)
  fi

  printf '%s\n' "${files[@]}"
}

# Generate configmap arguments for all utility files
# Format: "filename=./path/to/file"
get_utility_configmap_args() {
  local base_dir="${1:-./openshift/scripts}"
  local args=()

  # Add main utils file
  args+=("_utils.sh=$base_dir/_utils.sh")

  # Add all utility modules
  if [[ -d "$base_dir/utils" ]]; then
    while IFS= read -r -d '' file; do
      local basename=$(basename "$file")
      args+=("$basename=$file")
    done < <(find "$base_dir/utils" -name "*.sh" -type f -print0 | sort -z)
  fi

  printf '%s\n' "${args[@]}"
}
