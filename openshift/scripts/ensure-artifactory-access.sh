#!/bin/bash
# ensure-artifactory-access.sh
# Utility script to ensure all deployments have proper Artifactory imagePullSecrets

# Source the utility script
source ./openshift/scripts/_utils.sh

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