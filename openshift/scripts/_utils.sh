#!/bin/bash
#==============================================================================
# _utils.sh
#==============================================================================
# PURPOSE:
#   Main entry point for modular utility system. Loads and initializes all
#   utility modules, providing centralized access to deployment functions
#   across all OpenShift scripts.
#
# MODULAR ARCHITECTURE:
#   Core design separates concerns into focused, testable modules:
#
#   utils/openshift.sh   - Core OpenShift operations
#                          (create/update/delete resources, ConfigMaps, secrets,
#                           maintenance mode, scaling, logging functions)
#
#   utils/redis.sh       - Redis-specific operations
#                          (services, proxy, Sentinel configuration, health checks)
#
#   utils/database.sh    - Galera/MariaDB operations
#                          (cluster health checks, auto-healing, replication status,
#                           split-brain detection and recovery)
#
#   utils/moodle.sh      - Moodle-specific operations
#                          (course management, cache operations, content cleanup,
#                           CLI tool wrappers)
#
# CONFIGMAP COMPATIBILITY:
#   Supports both directory structure (utils/) and flat structure (all files
#   in same directory). This enables seamless operation whether sourced from
#   local filesystem or mounted as ConfigMap in OpenShift pods.
#
# INITIALIZATION:
#   1. Loads openshift.sh first (provides logging functions)
#   2. Loads remaining modules (redis, database, moodle)
#   3. Falls back to legacy inline mode if modules missing
#   4. Exports initialize_utility_arrays() for ConfigMap file tracking
#
# BACKWARD COMPATIBILITY:
#   - Maintains legacy global variables (timestamp_file, etc.)
#   - Provides fallback logging functions if modules missing
#   - Supports both sourcing methods: source _utils.sh or source ./utils/*.sh
#
# CONFIGURATION:
#   DEBUG_LEVEL                  - INFO/DEBUG (default: INFO)
#   CLUSTER_HEALTH_MONITORING    - YES/NO (default: YES)
#
# USAGE:
#   # Standard usage in deployment scripts
#   source ./openshift/scripts/_utils.sh
#   initialize_utility_arrays  # For ConfigMap operations
#
#   # Use any function from modules
#   create_or_update_configmap "my-config" "./config/file.conf"
#   check_galera_cluster_health
#   manage_maintenance_mode "enable" "maintenance-message"
#
# RELATED DOCS:
#   - Module Details: ./utils/README.md
#   - OpenShift Utils: ./utils/openshift.sh
#   - Database Utils: ./utils/database.sh
#   - Redis Utils: ./utils/redis.sh
#   - Moodle Utils: ./utils/moodle.sh
#==============================================================================

# =============================================================================
# MODULAR UTILITY LOADER - OPENSHIFT SCRIPTS
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
# NOTE: This MUST be loaded first as it defines the logging functions used below
if [[ -f "$UTILS_DIR/openshift.sh" ]]; then
  source "$UTILS_DIR/openshift.sh"
  log_debug "✅ Loaded OpenShift utilities module from $UTILS_DIR/openshift.sh"
elif [[ -f "$SCRIPT_DIR/openshift.sh" ]]; then
  # Fallback: Check if modules are in same directory (ConfigMap flat structure)
  source "$SCRIPT_DIR/openshift.sh"
  log_debug "✅ Loaded OpenShift utilities module from $SCRIPT_DIR/openshift.sh"
else
  echo "❌ ERROR: OpenShift utilities module not found"
  echo "   Searched: $UTILS_DIR/openshift.sh and $SCRIPT_DIR/openshift.sh"
  echo "   Falling back to legacy mode..."
  # Define minimal logging functions as fallback
  log_error() { echo "❌ $*" >&2; }
  log_warn() { echo "⚠️  $*"; }
  log_info() { echo "ℹ️  $*"; }
  log_debug() { [[ "${DEBUG_LEVEL}" == "DEBUG" ]] && echo "🔍 $*"; }
  log_success() { echo "✅ $*"; }
fi

# Load Redis-specific utilities
if [[ -f "$UTILS_DIR/redis.sh" ]]; then
  source "$UTILS_DIR/redis.sh"
  log_debug "✅ Loaded Redis utilities module"
elif [[ -f "$SCRIPT_DIR/redis.sh" ]]; then
  source "$SCRIPT_DIR/redis.sh"
  log_debug "✅ Loaded Redis utilities module (flat structure)"
else
  log_warn "⚠️  Redis utilities module not found - Redis operations unavailable"
fi

# Load Database utilities
if [[ -f "$UTILS_DIR/database.sh" ]]; then
  source "$UTILS_DIR/database.sh"
  log_debug "✅ Loaded Database utilities module"
elif [[ -f "$SCRIPT_DIR/database.sh" ]]; then
  source "$SCRIPT_DIR/database.sh"
  log_debug "✅ Loaded Database utilities module (flat structure)"
else
  log_warn "⚠️  Database utilities module not found - Galera operations unavailable"
fi

# Load Moodle utilities
if [[ -f "$UTILS_DIR/moodle.sh" ]]; then
  source "$UTILS_DIR/moodle.sh"
  log_debug "✅ Loaded Moodle utilities module"
elif [[ -f "$SCRIPT_DIR/moodle.sh" ]]; then
  source "$SCRIPT_DIR/moodle.sh"
  log_debug "✅ Loaded Moodle utilities module (flat structure)"
else
  log_warn "⚠️  Moodle utilities module not found - Moodle operations unavailable"
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

# Initialize utility file arrays and show debug output if enabled
# This function should be called by scripts that need utility file management
initialize_utility_arrays() {
  # Generate utility files list and configmap arguments dynamically
  mapfile -t UTILITY_FILES < <(get_utility_files)
  mapfile -t UTILITY_CONFIGMAP_ARGS < <(get_utility_configmap_args)

  # Export arrays so they're available to called scripts
  export UTILITY_FILES
  export UTILITY_CONFIGMAP_ARGS

  # Debug: Show what files will be included in configmaps
  if [[ "${DEBUG_LEVEL}" == "DEBUG" ]]; then
    log_debug "📋 Utility files for configmap inclusion (${#UTILITY_FILES[@]} files):"
    for file in "${UTILITY_FILES[@]}"; do
      log_debug "  - $file"
    done
    log_debug "📋 Configmap arguments (${#UTILITY_CONFIGMAP_ARGS[@]} args):"
    for arg in "${UTILITY_CONFIGMAP_ARGS[@]}"; do
      log_debug "  - $arg"
    done
  fi
}

# Validate all utility files syntax
# Returns 0 if all files pass validation, 1 if any fail
validate_utility_files() {
  log_debug "Validating utility files syntax..."

  local validation_failed=false
  for util_file in "${UTILITY_FILES[@]}"; do
    if [[ -f "$util_file" ]]; then
      if bash -n "$util_file"; then
        log_debug "Syntax validation passed for: $(basename "$util_file")"
      else
        log_error "Syntax validation failed for: $util_file"
        validation_failed=true
      fi
    else
      log_warn "Utility file not found: $util_file"
      validation_failed=true
    fi
  done

  if [[ "$validation_failed" == "true" ]]; then
    log_error "One or more utility files failed validation"
    return 1
  fi

  log_debug "All utility files passed syntax validation"
  return 0
}
