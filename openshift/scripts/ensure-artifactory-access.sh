#!/bin/bash
#==============================================================================
# ensure-artifactory-access.sh
#==============================================================================
# PURPOSE:
#   Ensure all OpenShift deployments and StatefulSets have proper Artifactory
#   imagePullSecrets configured. Required when USE_ARTIFACTORY=true to pull
#   container images from private Artifactory registry.
#
# RESOURCES CONFIGURED:
#   - deployment/moodle-backup          - Database backup container
#   - statefulset/mariadb-galera        - Database cluster
#   - statefulset/redis-node            - Redis cache cluster
#   - deployment/redis-proxy            - Redis connection proxy
#   - deployment/maintenance-message    - Maintenance page
#   - deployment/moodle-php             - PHP-FPM application
#   - deployment/moodle-web             - NGINX web server
#
# ARCHITECTURE:
#   1. Load centralized configuration (example.versions.env)
#   2. Call ensure_artifactory_access() utility function
#   3. Verify configuration on all applicable resources
#   4. Report status and any missing configurations
#
# CONFIGURATION:
#   ARTIFACTORY_PULL_SECRET  - Secret name (default: artifactory-m950-learning)
#   OC_PROJECT               - Target namespace
#
# USAGE:
#   # Configure all deployments
#   export ARTIFACTORY_PULL_SECRET="artifactory-m950-learning"
#   ./openshift/scripts/ensure-artifactory-access.sh
#
# RELATED DOCS:
#   - Utilities: ./_utils.sh (ensure_artifactory_access function)
#   - Configuration: ../../example.versions.env
#==============================================================================

# Universal _utils.sh loader - works in all environments
# Priority: same-dir > /scripts > /usr/local/bin > ./openshift/scripts
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

# Source environment variables from centralized configuration
if [[ -f "./example.versions.env" ]]; then
    source ./example.versions.env
    log_info "📋 Loaded centralized environment variables"
else
    log_warn "example.versions.env not found - using environment variables from deployment"
fi

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

log_info "🏭 Ensuring Artifactory access for all deployments"
log_info "📋 Using imagePullSecret: ${ARTIFACTORY_PULL_SECRET:-artifactory-m950-learning}"

# Use the automated function that handles all common deployments
if ensure_artifactory_access "$OC_PROJECT"; then
    log_success "✅ Artifactory access configured for all applicable deployments"
else
    log_warn "⚠️ Some deployments may not have been updated"
    exit 1
fi

log_info ""
log_info "🔍 Verification - checking current imagePullSecrets status:"

# Verify the configuration by checking each resource
resources_to_check=(
    "deployment/$DB_BACKUP_DEPLOYMENT_FULL_NAME"
    "statefulset/$DB_DEPLOYMENT_NAME"
    "statefulset/$REDIS_NAME-node"
    "deployment/$REDIS_PROXY_NAME"
    "deployment/maintenance-message"
)

for resource in "${resources_to_check[@]}"; do
    resource_type="${resource%/*}"
    resource_name="${resource#*/}"

    if [[ -n "$resource_name" ]] && oc get "$resource_type" "$resource_name" &>/dev/null; then
        secrets=$(oc get "$resource_type" "$resource_name" -o jsonpath='{.spec.template.spec.imagePullSecrets[*].name}' 2>/dev/null)
        if [[ "$secrets" == *"${ARTIFACTORY_PULL_SECRET:-artifactory-m950-learning}"* ]]; then
            log_info "  ✅ $resource: Configured"
        else
            log_warn "  ❌ $resource: Missing imagePullSecrets (secrets: ${secrets:-none})"
        fi
    else
        log_debug "  ⏭️  $resource: Not found (skipped)"
    fi
done

log_info ""
log_success "🎉 Artifactory access verification completed"