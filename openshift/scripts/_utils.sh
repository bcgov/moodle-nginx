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

# =============================================================================
# INTELLIGENT PATH RESOLUTION STRATEGY
# =============================================================================
# Supports multiple ConfigMap mounting strategies for maximum flexibility:
#
# STRATEGY 1: Natural Subdirectories (FUTURE-PROOF, RECOMMENDED)
#   - ConfigMap uses items[].path to preserve repo structure
#   - Example: key="utils-openshift.sh" path="utils/openshift.sh"
#   - Result: /scripts/utils/openshift.sh
#   - Pros: Matches repo structure, no translation needed
#   - Cons: Requires explicit items[] mapping in pod spec (verbose but clean)
#
# STRATEGY 2: Flattened Keys (CURRENT, AUTOMATIC)
#   - ConfigMap keys flattened: utils/openshift.sh → utils-openshift.sh
#   - Mounted directly without items[]
#   - Result: /scripts/utils-openshift.sh
#   - Pros: Automatic file discovery, no manual mapping
#   - Cons: Path translation needed (different from repo)
#
# STRATEGY 3: Flat Mount (LEGACY, DEPRECATED)
#   - All scripts mounted at same level (no subdirectories)
#   - Result: /scripts/openshift.sh
#   - Pros: Simple
#   - Cons: Name collisions, no organization
#
# Detection order (best to fallback):
#   1. Natural subdirs: utils/openshift.sh (preferred if items[] mapping exists)
#   2. Flattened keys:  utils-openshift.sh  (current automatic approach)
#   3. Flat mount:      openshift.sh        (legacy fallback)
#
# Related: docs/galera-deployment-best-practices.md#configmap-path-strategy
# =============================================================================

# Detect structure type
if [[ -d "$SCRIPT_DIR/utils" && -f "$SCRIPT_DIR/utils/openshift.sh" ]]; then
  # STRATEGY 1: Natural subdirectory structure (future items[] approach or local dev)
  UTILS_DIR="$SCRIPT_DIR/utils"
  UTILS_PREFIX=""
  log_trace "Detected natural subdirectory structure: $UTILS_DIR" 2>/dev/null || true
elif [[ -f "$SCRIPT_DIR/utils-openshift.sh" ]]; then
  # STRATEGY 2: Flattened ConfigMap keys (current production approach)
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX="utils-"
  log_trace "Detected flattened ConfigMap structure at $SCRIPT_DIR" 2>/dev/null || true
elif [[ -f "$SCRIPT_DIR/openshift.sh" ]]; then
  # STRATEGY 3: Flat structure (legacy ConfigMap mount)
  UTILS_DIR="$SCRIPT_DIR"
  UTILS_PREFIX=""
  log_trace "Detected flat ConfigMap structure at $SCRIPT_DIR" 2>/dev/null || true
else
  # Unknown structure - try utils/ subdirectory anyway
  UTILS_DIR="$SCRIPT_DIR/utils"
  UTILS_PREFIX=""
  log_trace "Unknown structure, defaulting to utils/ subdirectory" 2>/dev/null || true
fi

# Global variables for backward compatibility
timestamp_file='/var/www/html/last_migration_timestamp'

# Set default debug level if not provided
DEBUG_LEVEL="${DEBUG_LEVEL:-INFO}"

# Set default cluster health monitoring if not provided
CLUSTER_HEALTH_MONITORING="${CLUSTER_HEALTH_MONITORING:-YES}"

# =============================================================================
# CORE MODULE LOADING (Week 1-2 Foundation - April 2026)
# =============================================================================
# DEPENDENCY ORDER:
#   Week 1 Foundation:
#   1. logging.sh       - No dependencies (provides log_* functions)
#   2. validation.sh    - Depends on logging
#   3. coordination.sh  - Depends on logging, validation
#
#   Week 2 Core Services:
#   4. cluster-health.sh - Depends on logging (health monitoring, event tracking)
#   5. monitoring.sh     - Depends on logging, validation, cluster-health
#   6. secrets.sh        - Depends on logging, validation
#   7. pvc.sh            - Depends on logging
#
#   Legacy & Domain Modules:
#   8. openshift.sh     - Legacy monolith (resource management, scaling, maintenance)
#   9. redis.sh         - Domain-specific operations
#   10. database.sh     - Domain-specific operations
#   11. moodle.sh       - Domain-specific operations
#
# REFACTORING PROGRESS:
#   Week 1: logging, validation, coordination extracted (1,350 lines)
#   Week 2: cluster-health, monitoring, secrets, pvc extracted (1,400 lines)
#   Remaining in openshift.sh: ~700 lines (resources, scaling, maintenance)
#
#   See: docs/openshift-utilities-refactoring-plan.md
# =============================================================================

# Load logging utilities FIRST (no dependencies, provides log_* functions)
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}logging.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}logging.sh"
  log_debug "Loaded logging utilities module (Week 1 Foundation)"
else
  # Define minimal logging functions as fallback for legacy mode
  log_error() { echo "❌ $*" >&2; }
  log_warn() { echo "⚠️  $*" >&2; }
  log_info() { echo "ℹ️  $*" >&2; }
  log_success() { echo "✅ $*"; }
  log_debug() { [[ "${DEBUG_LEVEL}" == "DEBUG" || "${DEBUG_LEVEL}" == "TRACE" ]] && echo "🔍 Debug: $*" >&2; }
  log_trace() { [[ "${DEBUG_LEVEL}" == "TRACE" ]] && echo "🔬 Trace: $*" >&2; }
  log_header() { echo "" >&2; echo "═══════════════════════════════════════════════════════════════════" >&2; echo "  $*" >&2; echo "═══════════════════════════════════════════════════════════════════" >&2; echo "" >&2; }
  echo_field() { printf "%-${3:-30}s: %s\n" "$1" "$2" >&2; }
  log_warn "Logging module not found - using fallback functions"
fi

# Load validation utilities (depends on logging)
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}validation.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}validation.sh"
  log_debug "Loaded validation utilities module (Week 1 Foundation)"
else
  log_warn "Validation module not found - validation operations unavailable"
fi

# Load coordination utilities (depends on logging, validation)
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}coordination.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}coordination.sh"
  log_debug "Loaded coordination utilities module (Week 1 Foundation)"
else
  log_debug "Coordination module not found (optional) - pod-health-monitor coordination unavailable"
fi

# =============================================================================
# WEEK 2 CORE SERVICES (April 2026)
# =============================================================================

# Load cluster health monitoring (depends on logging)
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}cluster-health.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}cluster-health.sh"
  log_debug "Loaded cluster-health module (Week 2 Core Services)"
else
  log_warn "Cluster-health module not found - health monitoring unavailable"
fi

# Load monitoring and wait functions (depends on logging, validation, cluster-health)
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}monitoring.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}monitoring.sh"
  log_debug "Loaded monitoring module (Week 2 Core Services)"
else
  log_warn "Monitoring module not found - wait functions unavailable"
fi

# Load secret management (depends on logging, validation)
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}secrets.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}secrets.sh"
  log_debug "Loaded secrets module (Week 2 Core Services)"
else
  log_warn "Secrets module not found - secret management unavailable"
fi

# Load PVC management (depends on logging)
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}pvc.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}pvc.sh"
  log_debug "Loaded PVC module (Week 2 Core Services)"
else
  log_warn "PVC module not found - PVC expand operations unavailable"
fi

# =============================================================================
# LEGACY MONOLITH & DOMAIN MODULES
# =============================================================================

# Load core OpenShift utilities (legacy monolith - continues refactoring)
# NOTE: Weeks 1-2 extracted 3,350 lines to modular utilities.
#       Remaining ~700 lines contain: scaling, resource mgmt, HPA, platform utils
#       Week 3 will extract these into resources.sh, scaling.sh, maintenance.sh
#       Original 3,443-line monolith archived as: openshift-legacy.sh
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}openshift.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}openshift.sh"
  log_debug "Loaded OpenShift utilities module (minimal, ~700 lines remaining)"
else
  log_error "OpenShift utilities module not found at $UTILS_DIR/${UTILS_PREFIX}openshift.sh"
  echo "   SCRIPT_DIR=$SCRIPT_DIR" >&2
  echo "   UTILS_DIR=$UTILS_DIR" >&2
  echo "   UTILS_PREFIX=$UTILS_PREFIX" >&2
  log_error "Critical module missing - some operations will fail"
fi

# Load Redis-specific utilities
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}redis.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}redis.sh"
  log_debug "Loaded Redis utilities module"
else
  log_warn "Redis utilities module not found - Redis operations unavailable"
fi

# Load shared Galera utilities
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}_galera_utils.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}_galera_utils.sh"
  log_debug "Loaded shared Galera utilities module"
else
  log_debug "Shared Galera utilities module not found (optional)"
fi

# Load Database utilities
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}database.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}database.sh"
  log_debug "Loaded Database utilities module"
else
  log_warn "Database utilities module not found - Galera operations unavailable"
fi

# Load Moodle utilities
if [[ -f "$UTILS_DIR/${UTILS_PREFIX}moodle.sh" ]]; then
  source "$UTILS_DIR/${UTILS_PREFIX}moodle.sh"
  log_debug "Loaded Moodle utilities module"
else
  log_warn "Moodle utilities module not found - Moodle operations unavailable"
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
    log_debug "DEBUG: Utility files for configmap inclusion (${#UTILITY_FILES[@]} files):"
    for file in "${UTILITY_FILES[@]}"; do
      log_debug "  - $file"
    done
    log_debug "DEBUG: Configmap arguments (${#UTILITY_CONFIGMAP_ARGS[@]} args):"
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
