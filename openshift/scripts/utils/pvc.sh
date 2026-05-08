#!/bin/bash
# =============================================================================
# pvc.sh - PVC Management & Expansion Functions
# =============================================================================
# PURPOSE:
#   Provides PersistentVolumeClaim (PVC) expansion utilities with StorageClass
#   validation, capacity conversion, and StatefulSet PVC batch operations.
#
# CORE FUNCTIONS:
#   - check_storage_class_expansion() - Verify StorageClass supports expansion
#   - convert_capacity_to_mib() - Normalize capacity units to MiB
#   - get_pvc_capacity_mib() - Get current PVC capacity
#   - expand_pvc() - Expand single PVC with wait & verification
#   - expand_statefulset_pvcs() - Batch expand all StatefulSet PVCs
#
# USAGE:
#   source ./openshift/scripts/utils/pvc.sh
#
#   # Check if expansion supported
#   if check_storage_class_expansion "data-mariadb-galera-0" "$namespace"; then
#     echo "Expansion supported"
#   fi
#
#   # Expand single PVC
#   expand_pvc "data-mariadb-galera-0" 2048 "$namespace" false
#
#   # Expand all PVCs for a StatefulSet
#   expand_statefulset_pvcs "mariadb-galera" 2048 3 "$namespace" false
#
# IMPORTANT NOTES:
#   - PVC expansion is one-way only (cannot shrink)
#   - Scaling StatefulSet to 0 before expansion is safer
#   - Some StorageClasses don't support online expansion
#   - Expansion may require pod restart depending on filesystem
#
# ENVIRONMENT VARIABLES:
#   DEPLOY_NAMESPACE - Target namespace (required)
#
# DEPENDENCIES:
#   - logging.sh (log_* functions)
#
# RELATED DOCS:
#   - docs/galera-deployment-best-practices.md
#   - https://kubernetes.io/docs/concepts/storage/persistent-volumes/#expanding-persistent-volumes-claims
# =============================================================================

# =============================================================================
# STORAGECLASS VALIDATION
# =============================================================================

# Function to check if a StorageClass supports volume expansion
check_storage_class_expansion() {
  local pvc_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  # Get the StorageClass name from the PVC
  local storage_class
  storage_class=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.storageClassName}' 2>/dev/null)

  if [[ -z "$storage_class" ]]; then
    log_error "❌ Could not determine StorageClass for PVC: $pvc_name"
    return 1
  fi

  # Check if the StorageClass allows volume expansion
  local allows_expansion
  allows_expansion=$(oc get storageclass "$storage_class" -o jsonpath='{.allowVolumeExpansion}' 2>/dev/null)

  if [[ "$allows_expansion" == "true" ]]; then
    log_debug "✅ StorageClass '$storage_class' supports volume expansion"
    return 0
  else
    log_warn "⚠️ StorageClass '$storage_class' does not support volume expansion"
    log_warn "   PVC: $pvc_name"
    log_warn "   This may require manual intervention or StorageClass update"
    return 1
  fi
}

# =============================================================================
# CAPACITY CONVERSION UTILITIES
# =============================================================================

# Function to convert PVC capacity to consistent units (MiB)
convert_capacity_to_mib() {
  local capacity="$1"

  # Remove whitespace
  capacity=$(echo "$capacity" | tr -d '[:space:]')

  # Extract number and unit
  local value unit
  if [[ "$capacity" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
    value="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
  else
    log_error "❌ Invalid capacity format: $capacity"
    return 1
  fi

  # Convert to MiB
  case "${unit^^}" in
    ""|"MIB"|"MI")
      echo "$value"
      ;;
    "GIB"|"GI"|"G")
      echo $((value * 1024))
      ;;
    "TIB"|"TI"|"T")
      echo $((value * 1024 * 1024))
      ;;
    "KIB"|"KI"|"K")
      echo $((value / 1024))
      ;;
    *)
      log_error "❌ Unsupported capacity unit: $unit"
      return 1
      ;;
  esac
}

# Function to get current PVC capacity in MiB
get_pvc_capacity_mib() {
  local pvc_name="$1"
  local namespace="${2:-$DEPLOY_NAMESPACE}"

  local capacity
  capacity=$(oc get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.status.capacity.storage}' 2>/dev/null)

  if [[ -z "$capacity" ]]; then
    log_error "❌ Could not get capacity for PVC: $pvc_name"
    return 1
  fi

  convert_capacity_to_mib "$capacity"
}

# =============================================================================
# PVC EXPANSION
# =============================================================================

# Function to expand a single PVC
expand_pvc() {
  local pvc_name="$1"
  local target_size_mib="$2"
  local namespace="${3:-$DEPLOY_NAMESPACE}"
  local dry_run="${4:-false}"

  log_info "🔍 Checking PVC: $pvc_name"

  # Check if PVC exists
  if ! oc get pvc "$pvc_name" -n "$namespace" &>/dev/null; then
    log_warn "⚠️ PVC not found: $pvc_name (may be created by StatefulSet later)"
    return 0  # Not an error - PVC might not exist yet
  fi

  # Check StorageClass supports expansion
  if ! check_storage_class_expansion "$pvc_name" "$namespace"; then
    log_warn "⚠️ Skipping PVC expansion (StorageClass limitation): $pvc_name"
    return 1
  fi

  # Get current capacity
  local current_size_mib
  current_size_mib=$(get_pvc_capacity_mib "$pvc_name" "$namespace")
  if [[ $? -ne 0 ]]; then
    log_error "❌ Failed to get current capacity for: $pvc_name"
    return 1
  fi

  log_debug "   Current: ${current_size_mib}Mi, Target: ${target_size_mib}Mi"

  # Compare sizes
  if [[ $target_size_mib -eq $current_size_mib ]]; then
    log_debug "   ✅ PVC already at target size"
    return 0
  elif [[ $target_size_mib -lt $current_size_mib ]]; then
    log_warn "   ⚠️ Target size (${target_size_mib}Mi) is smaller than current (${current_size_mib}Mi)"
    log_warn "   PVC shrinking is not supported in Kubernetes - skipping"
    return 0
  fi

  # Expansion needed
  local size_increase=$((target_size_mib - current_size_mib))
  log_info "   📈 Expanding PVC from ${current_size_mib}Mi to ${target_size_mib}Mi (+${size_increase}Mi)"

  if [[ "$dry_run" == "true" ]]; then
    log_info "   🔍 DRY RUN: Would expand PVC to ${target_size_mib}Mi"
    return 0
  fi

  # Perform the expansion
  if oc patch pvc "$pvc_name" -n "$namespace" -p "{\"spec\":{\"resources\":{\"requests\":{\"storage\":\"${target_size_mib}Mi\"}}}}" &>/dev/null; then
    log_success "   ✅ PVC expansion initiated: $pvc_name"

    # Wait for expansion to complete (with timeout)
    local attempts=0
    local max_attempts=30  # 5 minutes
    local expanded=false

    while [[ $attempts -lt $max_attempts ]]; do
      local new_size_mib
      new_size_mib=$(get_pvc_capacity_mib "$pvc_name" "$namespace")

      if [[ $new_size_mib -ge $target_size_mib ]]; then
        log_success "   ✅ PVC expansion completed: ${new_size_mib}Mi"
        expanded=true
        break
      fi

      log_debug "   ⏳ Waiting for expansion... (${attempts}0s)"
      sleep 10
      ((attempts++))
    done

    if [[ "$expanded" == "false" ]]; then
      log_warn "   ⚠️ PVC expansion timeout - may still be in progress"
      log_warn "   Check: oc get pvc $pvc_name -n $namespace"
    fi

    return 0
  else
    log_error "   ❌ Failed to expand PVC: $pvc_name"
    return 1
  fi
}

# =============================================================================
# STATEFULSET PVC BATCH OPERATIONS
# =============================================================================

# Function to expand PVCs for a StatefulSet based on CSV sizing
expand_statefulset_pvcs() {
  local statefulset_name="$1"
  local target_pvc_size_mib="$2"
  local expected_replica_count="$3"
  local namespace="${4:-$DEPLOY_NAMESPACE}"
  local dry_run="${5:-false}"

  log_info "🗄️ PVC Expansion Check for StatefulSet: $statefulset_name"
  log_info "   Target PVC Size: ${target_pvc_size_mib}Mi"
  log_info "   Expected Replicas: $expected_replica_count"

  # Verify StatefulSet exists
  if ! oc get statefulset "$statefulset_name" -n "$namespace" &>/dev/null; then
    log_error "❌ StatefulSet not found: $statefulset_name"
    return 1
  fi

  # Get current replica count
  local current_replicas
  current_replicas=$(oc get statefulset "$statefulset_name" -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null)

  if [[ -n "$current_replicas" && "$current_replicas" -ne 0 ]]; then
    log_warn "⚠️ StatefulSet has $current_replicas active replicas"
    log_warn "   PVC expansion is safer when replicas=0"
    log_warn "   Consider scaling down first to avoid sync issues during expansion"
  else
    log_success "✅ StatefulSet is scaled to 0 - safe for PVC expansion"
  fi

  # Find all PVCs for this StatefulSet
  local pvc_pattern="data-${statefulset_name}-"
  local pvcs
  pvcs=$(oc get pvc -n "$namespace" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr ' ' '\n' | grep "^${pvc_pattern}")

  if [[ -z "$pvcs" ]]; then
    log_warn "⚠️ No PVCs found matching pattern: ${pvc_pattern}*"
    log_info "   PVCs will be created when StatefulSet scales up"
    return 0
  fi

  # Count PVCs found
  local pvc_count
  pvc_count=$(echo "$pvcs" | wc -l)
  log_info "   Found $pvc_count PVC(s) for StatefulSet"

  # Process each PVC
  local expansion_count=0
  local skip_count=0
  local error_count=0

  while IFS= read -r pvc_name; do
    if expand_pvc "$pvc_name" "$target_pvc_size_mib" "$namespace" "$dry_run"; then
      expansion_count=$((expansion_count + 1))
    else
      if [[ $? -eq 1 ]]; then
        error_count=$((error_count + 1))  # True error
      else
        skip_count=$((skip_count + 1))    # Skipped (already at size, unsupported, etc.)
      fi
    fi
  done <<< "$pvcs"

  # Summary
  echo ""
  log_info "═══════════════════════════════════════════════════════════════════"
  log_info "  PVC Expansion Summary for StatefulSet: $statefulset_name"
  log_info "═══════════════════════════════════════════════════════════════════"
  log_info "   PVCs Processed:  $pvc_count"
  log_info "   Expanded:        $expansion_count"
  log_info "   Skipped:         $skip_count"
  log_info "   Errors:          $error_count"
  log_info "═══════════════════════════════════════════════════════════════════"
  echo ""

  if [[ $error_count -gt 0 ]]; then
    log_error "Some PVCs failed to expand"
    return 1
  elif [[ $expansion_count -gt 0 ]]; then
    log_success "PVC expansion completed successfully"

    # If StatefulSet is currently scaled to 0, remind user to scale up
    if [[ "$current_replicas" -eq 0 ]]; then
      log_info "💡 StatefulSet is currently scaled to 0"
      log_info "   Remember to scale up when ready:"
      log_info "   oc scale statefulset/$statefulset_name --replicas=$expected_replica_count -n $namespace"
    fi

    return 0
  else
    log_success "All PVCs already at target size or skipped"
    return 0
  fi
}
