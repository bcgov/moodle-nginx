#!/bin/bash
# =============================================================================
# secrets.sh - Secret & ConfigMap Management
# =============================================================================
# PURPOSE:
#   Provides comprehensive secret and ConfigMap management with validation,
#   creation/update tracking, and resource restart coordination.
#
# CORE FUNCTIONS:
#   - get_secret_value() - Retrieve and decode secret values
#   - validate_secret_values() - Verify secret contains expected values
#   - create_or_update_secret() - Create/replace secrets with data pairs
#   - manage_secret_with_validation() - Create secrets with validation
#   - create_or_update_configmap() - ConfigMap creation from files
#   - restart_resource() - Restart deployments/statefulsets after config changes
#   - ensure_statefulset_partition() - StatefulSet partition management
#   - restart_deployment() - Legacy wrapper for restart_resource
#
# USAGE:
#   source ./openshift/scripts/utils/secrets.sh
#
#   # Get secret value
#   db_password=$(get_secret_value "moodle-secrets" "DB_PASSWORD" "$namespace")
#
#   # Create/update secret
#   create_or_update_secret "my-secret" "key1=value1,key2=value2" "$namespace"
#
#   # Restart deployment after secret change
#   restart_resource "deployment" "php" "$namespace" "300s" "secret update"
#
# ENVIRONMENT VARIABLES:
#   DEPLOY_NAMESPACE - Target namespace (required)
#
# DEPENDENCIES:
#   - logging.sh (log_* functions)
#   - validation.sh (resource_exists)
#
# RELATED DOCS:
#   - docs/galera-deployment-best-practices.md
# =============================================================================

# =============================================================================
# SECRET VALUE RETRIEVAL
# =============================================================================

# Function to validate and get current secret values
get_secret_value() {
  local secret_name="$1"
  local key="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  if oc get secret "$secret_name" -n "$namespace" &>/dev/null; then
    # Get the base64 encoded value and decode it
    oc get secret "$secret_name" -n "$namespace" -o jsonpath="{.data.$key}" 2>/dev/null | base64 -d 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# =============================================================================
# SECRET VALIDATION
# =============================================================================

# Function to validate if secret values match expected values
validate_secret_values() {
  local secret_name="$1"
  local expected_values="$2"  # Format: "key1=value1,key2=value2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  if ! oc get secret "$secret_name" -n "$namespace" &>/dev/null; then
    log_error "Secret '$secret_name' does not exist"
    return 1
  fi

  log_info "Validating secret '$secret_name' values..."

  # Parse expected values
  IFS=',' read -ra expected_pairs <<< "$expected_values"
  local validation_failed=false

  for pair in "${expected_pairs[@]}"; do
    if [[ "$pair" == *"="* ]]; then
      local key="${pair%%=*}"
      local expected_value="${pair#*=}"
      local current_value
      current_value=$(get_secret_value "$secret_name" "$key" "$namespace")

      if [[ "$current_value" != "$expected_value" ]]; then
        log_error "Key '$key': value mismatch"
        validation_failed=true
      else
        log_success "Key '$key': value matches"
      fi
    fi
  done

  if [[ "$validation_failed" == "true" ]]; then
    return 1
  else
    log_success "All secret values validated successfully"
    return 0
  fi
}

# =============================================================================
# SECRET CREATION & UPDATES
# =============================================================================

# Function to create or update a secret
create_or_update_secret() {
  local secret_name="$1"
  local secret_data="$2"  # Format: "key1=value1,key2=value2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"

  log_info "Creating/updating secret '$secret_name'..."

  # Delete existing secret if it exists
  if oc get secret "$secret_name" -n "$namespace" &>/dev/null; then
    log_info "Deleting existing secret..."
    oc delete secret "$secret_name" -n "$namespace"
  fi

  # Parse secret data and build from-literal arguments array
  local from_literal_args=()
  IFS=',' read -ra data_pairs <<< "$secret_data"

  for pair in "${data_pairs[@]}"; do
    if [[ "$pair" == *"="* ]]; then
      local key="${pair%%=*}"
      local value="${pair#*=}"
      from_literal_args+=("--from-literal=${key}=${value}")
    fi
  done

  # Execute the command with proper argument handling
  if oc create secret generic "$secret_name" -n "$namespace" "${from_literal_args[@]}"; then
    log_success "Secret '$secret_name' created/updated successfully"
    return 0
  else
    log_error "Failed to create/update secret '$secret_name'"
    return 1
  fi
}

# Function to manage secrets with validation
manage_secret_with_validation() {
  local secret_name="$1"
  local secret_data="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local force_update="${4:-false}"

  log_info "Managing secret '$secret_name' with validation..."

  # If force_update is false, check if secret already exists and matches
  if [[ "$force_update" != "true" ]]; then
    if validate_secret_values "$secret_name" "$secret_data" "$namespace"; then
      log_success "Secret '$secret_name' already exists with correct values"
      return 0  # No changes needed
    fi
  fi

  # Create or update the secret
  if create_or_update_secret "$secret_name" "$secret_data" "$namespace"; then
    # Validate the created secret
    if validate_secret_values "$secret_name" "$secret_data" "$namespace"; then
      log_success "Secret '$secret_name' created and validated successfully"
      return 2  # Changes were made
    else
      log_error "Secret created but validation failed"
      return 1  # Error
    fi
  else
    log_error "Failed to create secret '$secret_name'"
    return 1  # Error
  fi
}

# =============================================================================
# CONFIGMAP MANAGEMENT
# =============================================================================

# Function to create or update a ConfigMap
create_or_update_configmap() {
  local configmap_name=$1
  shift
  local file_paths=("$@")

  delete_resource_if_exists configmap "$configmap_name"
  log_info "Creating ConfigMap: $configmap_name"

  # Construct the oc create configmap command with multiple --from-file flags
  local create_cmd="oc create configmap $configmap_name"
  for file_path in "${file_paths[@]}"; do
    create_cmd+=" --from-file=$file_path"
  done

  # Execute the command
  eval "$create_cmd"
}

# =============================================================================
# RESOURCE RESTART COORDINATION
# =============================================================================

# Generic function to restart any Kubernetes resource (deployment, statefulset, daemonset)
restart_resource() {
  local resource_type="$1"   # e.g., "deployment", "statefulset", "daemonset"
  local resource_name="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local timeout="${4:-300s}"
  local reason="${5:-configuration changes}"

  log_info "🔄 Restarting $resource_type '$resource_name' to pick up $reason..."

  # Standardize resource type names
  case "$resource_type" in
    "sts") resource_type="statefulset" ;;
    "deploy") resource_type="deployment" ;;
    "ds") resource_type="daemonset" ;;
  esac

  # Check if resource exists
  if ! oc get "$resource_type" "$resource_name" -n "$namespace" &>/dev/null; then
    log_error "$resource_type '$resource_name' not found in namespace '$namespace'"
    return 1
  fi

  # Initiate rollout restart
  if oc rollout restart "$resource_type/$resource_name" -n "$namespace"; then
    log_info "$resource_type '$resource_name' restart initiated"

    # Wait for the rollout to complete
    if oc rollout status "$resource_type/$resource_name" -n "$namespace" --timeout="$timeout"; then
      log_success "$resource_type '$resource_name' restart completed successfully"
      return 0
    else
      log_error "$resource_type '$resource_name' restart timed out or failed after $timeout"
      return 1
    fi
  else
    log_error "Failed to restart $resource_type '$resource_name'"
    return 1
  fi
}

# Utility function to ensure StatefulSet partition is set correctly for updates
# Kubernetes won't restart pods if partition >= replica count
ensure_statefulset_partition() {
  local statefulset_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  log_debug "Checking StatefulSet partition for $statefulset_name..."

  # Get current partition value
  local current_partition
  current_partition=$(oc get statefulset "$statefulset_name" -n "$namespace" \
    -o jsonpath='{.spec.updateStrategy.rollingUpdate.partition}' 2>/dev/null)

  # Get current replica count
  local replica_count
  replica_count=$(oc get statefulset "$statefulset_name" -n "$namespace" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null)

  # If partition is set and >= replica count, pods won't restart
  if [[ -n "$current_partition" && "$current_partition" -ge "$replica_count" ]]; then
    log_warn "StatefulSet partition ($current_partition) >= replicas ($replica_count)"
    log_warn "Resetting partition to 0 to allow updates..."

    if oc patch statefulset "$statefulset_name" -n "$namespace" \
         -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":0}}}}'; then
      log_success "StatefulSet partition reset to 0"
    else
      log_error "Failed to reset StatefulSet partition"
      return 1
    fi
  else
    log_debug "StatefulSet partition is correctly configured"
  fi

  return 0
}

# Backward compatibility wrapper: restart deployments when secrets change
restart_deployment() {
  local deployment_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  restart_resource "deployment" "$deployment_name" "$namespace" "300s" "secret changes"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Function to delete a resource if it exists
delete_resource_if_exists() {
  local resource_type=$1
  local resource_name=$2

  echo "Checking if $resource_type exists: $resource_name"

  # Use oc get to check if the resource exists
  if oc get "$resource_type" "$resource_name" &>/dev/null; then
    echo "Deleting existing $resource_type: $resource_name"
    oc delete "$resource_type" "$resource_name"
  else
    echo "$resource_type does not exist: $resource_name"
  fi
}
