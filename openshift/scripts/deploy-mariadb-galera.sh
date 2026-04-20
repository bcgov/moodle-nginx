#!/bin/bash
#==============================================================================
# deploy-mariadb-galera.sh
#==============================================================================
# PURPOSE:
#   Deploy MariaDB Galera cluster to OpenShift using a tiered strategy that
#   detects what changed and reacts proportionally -- avoiding unnecessary
#   cluster destruction and the split-brain risks that come with it.
#
# TIERED DEPLOYMENT STRATEGY:
#   +------------------------------------------------------------------------+
#   | Tier 1 -- ConfigMaps          Always (cheap, no pod restart)           |
#   | Tier 2 -- Version Guard       Abort on major/breaking image change     |
#   | Tier 3 -- Helm Release        Fresh install OR skip OR upgrade         |
#   | Tier 4 -- Post-deploy         Patches, health checks, data verify     |
#   +------------------------------------------------------------------------+
#
# UPGRADE STRATEGY (Tier 3 -- when changes detected):
#   1. Pre-check: verify galera-0 is safe to bootstrap from
#   2. Scale StatefulSet to 0 (OrderedReady = galera-0 shuts down last)
#   3. Delete secondary PVCs (eliminates all stale state)
#   4. Helm upgrade: forceBootstrap=true, replicaCount=1 (galera-0 bootstraps)
#   5. Wait for galera-0 Ready + data on its existing PVC
#   6. Helm upgrade: forceBootstrap=false, replicaCount=$DB_REPLICAS
#   7. OrderedReady ensures secondaries start sequentially and SST from primary
#
#   Uses galera_verify_bootstrap_safe() and galera_delete_secondary_pvcs()
#   from utils/database.sh -- shared with the health monitor's auto-heal.
#
# VERSION GUARD (Tier 2):
#   Detects breaking changes before they reach the cluster:
#   - Image repository change (different product)    -> ABORT
#   - Major version change (e.g., 10.6 -> 11.0)     -> ABORT
#   - Version downgrade                              -> ABORT
#   - Minor/patch version change                     -> Rolling update
#   Override: set ALLOW_MAJOR_DB_UPGRADE=yes after manual review
#
# QUICK CONFIG:
#   DB_DEPLOYMENT_NAME       - StatefulSet name (default: mariadb-galera)
#   DB_REPLICAS              - Target replica count (sizing CSV must match)
#   USE_ARTIFACTORY          - Pull from Artifactory vs. public registry
#   MARIADB_IMAGE            - Image name:tag (resolved via helm-image-resolver.sh)
#   ALLOW_MAJOR_DB_UPGRADE   - "yes" to bypass major version guard
#
# USAGE:
#   # Standard deployment (detects changes automatically)
#   ./openshift/scripts/deploy-mariadb-galera.sh
#
#   # After reviewing a major version change
#   export ALLOW_MAJOR_DB_UPGRADE=yes
#   ./openshift/scripts/deploy-mariadb-galera.sh
#
# RELATED DOCS:
#   - Architecture: ../../docs/galera-monitoring-solution.md
#   - Troubleshooting: ../../docs/manual-galera-troubleshooting.md
#   - Configuration: ../../config/mariadb/my.cnf
#   - Helm Values: ../../config/mariadb/galera-values.yaml
#   - PreStop Patch: ../../config/mariadb/mariadb-galera-prestop-patch.json
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

# =============================================================================
# FAILURE CLEANUP -- ensure the StatefulSet is in a safe, re-runnable state
# =============================================================================
# If we fail mid-upgrade (possibly after scaling to 1), restore the cluster
# to its target replica count so it remains operational.
# =============================================================================
galera_cleanup() {
  local exit_code=$?
  [[ $exit_code -eq 0 ]] && return 0

  echo ""
  echo "========================================================"
  echo "GALERA DEPLOYMENT FAILED (exit code: $exit_code)"
  echo "========================================================"

  # If Helm release exists, ensure safe template state
  if helm list -q 2>/dev/null | grep -q "^${DB_DEPLOYMENT_NAME:-mariadb-galera}$"; then
    echo "Ensuring safe StatefulSet state for re-run..."
    oc set env statefulset/${DB_DEPLOYMENT_NAME} \
      "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
      "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
      -n "$DEPLOY_NAMESPACE" 2>/dev/null || true
    oc patch statefulset/${DB_DEPLOYMENT_NAME} -n "$DEPLOY_NAMESPACE" \
      -p '{"spec":{"updateStrategy":{"type":"RollingUpdate","rollingUpdate":null}}}' 2>/dev/null || true

    # If we failed after scaling to 0, try to bring the cluster back
    CURRENT_REPLICAS=$(oc get sts/${DB_DEPLOYMENT_NAME} -n "$DEPLOY_NAMESPACE" \
      -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
    if [[ "$CURRENT_REPLICAS" == "0" ]]; then
      echo "   Cluster is at 0 replicas -- attempting bootstrap recovery..."
      oc set env statefulset/${DB_DEPLOYMENT_NAME} \
        "MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes" \
        "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes" \
        -n "$DEPLOY_NAMESPACE" 2>/dev/null || true
      oc scale sts/${DB_DEPLOYMENT_NAME} --replicas=1 -n "$DEPLOY_NAMESPACE" 2>/dev/null || true
      echo "   Scaled to 1 with bootstrap=yes -- verify galera-0 health manually"
    elif [[ "$CURRENT_REPLICAS" == "1" && "${DB_REPLICAS:-2}" -gt 1 ]]; then
      echo "   Cluster at 1 replica -- scaling to ${DB_REPLICAS}..."
      oc scale sts/${DB_DEPLOYMENT_NAME} --replicas=${DB_REPLICAS} -n "$DEPLOY_NAMESPACE" 2>/dev/null || true
    fi
    echo "   Template restored: BOOTSTRAP=no, RollingUpdate strategy"
  fi

  # Environment-aware guidance
  if [[ "$DEPLOY_NAMESPACE" == *"-prod"* ]]; then
    echo ""
    echo "PRODUCTION -- site left in maintenance mode for manual review."
    echo "   Check cluster state:"
    echo "   oc get pods -l app.kubernetes.io/name=${DB_DEPLOYMENT_NAME} -n $DEPLOY_NAMESPACE"
    echo "   oc get sts/${DB_DEPLOYMENT_NAME} -n $DEPLOY_NAMESPACE"
  fi

  echo ""
  echo "This script is safe to re-run after resolving the issue."
  echo "Deploy script exiting with code $exit_code"
}
trap galera_cleanup EXIT

# Load environment variables from versions file
if [[ -f "./example.versions.env" ]]; then
    source ./example.versions.env
else
    log_warn "example.versions.env not found - using environment variables from deployment"
fi

# Source Helm image resolver for DRY image management
source ./openshift/scripts/helm-image-resolver.sh

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

echo "Deploying MariaDB Galera to: $DB_DEPLOYMENT_NAME..."

# Resolve DB_REPLICAS from the per-environment sizing CSV (authoritative source).
# The CSV is environment-specific (e.g., 950003-prod-sizing.csv has 5 replicas,
# dev/test have 2), eliminating cross-environment merge conflicts in example.env.
# Falls back to DB_REPLICAS from env var / example.env if CSV is unavailable.
SIZING_CSV="./openshift/${DEPLOY_NAMESPACE}-sizing.csv"
if [[ -f "$SIZING_CSV" ]]; then
  CSV_POD_COUNT=$(awk -F',' '$1 == "'"$DB_DEPLOYMENT_NAME"'" { print $3 }' "$SIZING_CSV" | tr -d ' ')
  if [[ -n "$CSV_POD_COUNT" && "$CSV_POD_COUNT" -gt 0 ]]; then
    if [[ "$CSV_POD_COUNT" != "$DB_REPLICAS" ]]; then
      log_warn "DB_REPLICAS=$DB_REPLICAS (env) overridden by sizing CSV PodCount=$CSV_POD_COUNT"
    fi
    DB_REPLICAS="$CSV_POD_COUNT"
  fi
  echo "DB_REPLICAS=$DB_REPLICAS (from $SIZING_CSV)"
else
  echo "Sizing CSV not found: $SIZING_CSV -- using DB_REPLICAS=$DB_REPLICAS from environment"
fi

log_debug "DEBUG: USE_ARTIFACTORY=$USE_ARTIFACTORY"
log_debug "DEBUG: HELM_REPO=$HELM_REPO"
log_debug "DEBUG: ARTIFACTORY_REGISTRY=$ARTIFACTORY_REGISTRY"
log_debug "DEBUG: MARIADB_IMAGE=$MARIADB_IMAGE"
log_debug "DEBUG: RESOLVED_IMAGE_REGISTRY=$RESOLVED_IMAGE_REGISTRY"
log_debug "DEBUG: RESOLVED_FULL_IMAGE=$RESOLVED_FULL_IMAGE"
log_debug "DEBUG: RESOLVED_IMAGE_REPOSITORY=$RESOLVED_IMAGE_REPOSITORY"
log_debug "DEBUG: RESOLVED_IMAGE_TAG=$RESOLVED_IMAGE_TAG"

# Validate Helm environment and show Artifactory status
if ! validate_helm_environment; then
    echo "Helm environment validation failed. Please check your environment variables."
    exit 1
fi

show_artifactory_status

# Resolve MariaDB image configuration
if ! resolve_helm_image "MARIADB_IMAGE"; then
    echo "Failed to resolve MARIADB_IMAGE configuration"
    exit 1
fi

echo "Using MariaDB image: ${RESOLVED_FULL_IMAGE}"

# =============================================================================
# TIER 1: ConfigMaps -- always updated (cheap, idempotent, no pod restart)
# =============================================================================
echo ""
echo "======================================================================="
echo "TIER 1: ConfigMaps"
echo "======================================================================="

echo "Creating ConfigMap mariadb-galera-configuration..."
create_or_update_configmap "mariadb-galera-configuration" "./config/mariadb/my.cnf"
oc label configmap mariadb-galera-configuration app.kubernetes.io/managed-by=Helm --overwrite
oc annotate configmap mariadb-galera-configuration meta.helm.sh/release-name=mariadb-galera --overwrite
oc annotate configmap mariadb-galera-configuration meta.helm.sh/release-namespace="${DEPLOY_NAMESPACE}" --overwrite

create_or_update_configmap "${DB_DEPLOYMENT_NAME}-prestop-script" "mariadb-prestop.sh=./openshift/scripts/mariadb-prestop.sh"

echo "ConfigMaps updated"

# =============================================================================
# TIER 1.5: Credentials Secret -- ensure passwords are in a K8s Secret
# =============================================================================
# The Bitnami chart's existingSecret feature reads passwords from a K8s Secret
# instead of Helm values. This prevents plaintext passwords from appearing in:
#   - helm get values output
#   - Helm release metadata (sh.helm.release.v1.*.vN secrets)
#   - Shell history and CI/CD logs
#
# Required keys: mariadb-root-password, mariadb-password,
#                mariadb-galera-mariabackup-password
# =============================================================================
echo ""
echo "======================================================================="
echo "TIER 1.5: Credentials Secret"
echo "======================================================================="

echo "Ensuring ${DB_DEPLOYMENT_NAME} credentials secret..."
oc create secret generic "$DB_DEPLOYMENT_NAME" \
  --from-literal=mariadb-root-password="$DB_PASSWORD" \
  --from-literal=mariadb-password="$DB_PASSWORD" \
  --from-literal=mariadb-galera-mariabackup-password="$DB_PASSWORD" \
  --dry-run=client --save-config -o yaml | oc apply -f -

# Prevent Helm from deleting this secret during uninstall/upgrade
oc annotate secret "$DB_DEPLOYMENT_NAME" helm.sh/resource-policy=keep --overwrite 2>/dev/null || true
oc label secret "$DB_DEPLOYMENT_NAME" app.kubernetes.io/name="$DB_DEPLOYMENT_NAME" --overwrite 2>/dev/null || true

echo "Credentials secret verified (passwords stored in K8s Secret, not Helm values)"

# =============================================================================
# TIER 2 & 3: Version Guard -> Fresh Install / Skip / Rolling Upgrade
# =============================================================================
echo ""
echo "======================================================================="
echo "TIER 2/3: Helm Release Management"
echo "======================================================================="

PATCH_FILE="config/mariadb/mariadb-galera-prestop-patch.json"
HELM_ACTION=""  # Will be set to: install, upgrade, or skip

if helm list -q | grep -q "^$DB_DEPLOYMENT_NAME$"; then
  echo "$DB_DEPLOYMENT_NAME Helm release found -- checking for changes..."

  # -------------------------------------------------------------------------
  # VERSION GUARD: detect breaking image changes before they hit the cluster
  # Uses detect_breaking_image_change() from utils/database.sh
  # -------------------------------------------------------------------------
  LIVE_IMAGE=$(oc get sts/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "")
  LIVE_REPLICAS=$(oc get sts/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" \
    -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")

  if [[ -n "$LIVE_IMAGE" && "$LIVE_IMAGE" != "$RESOLVED_FULL_IMAGE" ]]; then
    detect_breaking_image_change "$LIVE_IMAGE" "$RESOLVED_FULL_IMAGE" "${ALLOW_MAJOR_DB_UPGRADE:-no}"
    CHANGE_LEVEL=$?

    case $CHANGE_LEVEL in
      0|1)
        # Compatible or minor change -- safe for rolling update
        ;;
      2)
        # Major version change
        if [[ "${ALLOW_MAJOR_DB_UPGRADE:-no}" != "yes" ]]; then
          echo ""
          echo "Set ALLOW_MAJOR_DB_UPGRADE=yes in your pipeline environment to proceed."
          echo "   This deployment is safe to re-run after the issue is addressed or reverted."
          exit 1
        fi
        echo "WARNING: Proceeding with major upgrade (ALLOW_MAJOR_DB_UPGRADE=yes)"
        ;;
      3)
        # Repository/product change -- always abort
        echo ""
        echo "This requires manual migration. Automated deployment cannot proceed."
        echo "   This deployment is safe to re-run after the issue is addressed or reverted."
        exit 1
        ;;
      4)
        # Downgrade -- always abort
        echo ""
        echo "Revert MARIADB_IMAGE in example.versions.env and re-run."
        exit 1
        ;;
    esac
  fi

  # -------------------------------------------------------------------------
  # CHANGE DETECTION: compare live state vs desired state
  # -------------------------------------------------------------------------
  CHANGES=()
  if [[ "$LIVE_IMAGE" != "$RESOLVED_FULL_IMAGE" ]]; then
    CHANGES+=("image: $LIVE_IMAGE -> $RESOLVED_FULL_IMAGE")
  fi
  if [[ "$LIVE_REPLICAS" != "$DB_REPLICAS" ]]; then
    CHANGES+=("replicas: $LIVE_REPLICAS -> $DB_REPLICAS")
  fi

  if [[ ${#CHANGES[@]} -eq 0 ]]; then
    echo "No changes detected -- Helm upgrade not required"
    echo "   Live image:    $LIVE_IMAGE"
    echo "   Live replicas: $LIVE_REPLICAS"
    HELM_ACTION="skip"
  else
    echo "Changes detected -- performing safe upgrade:"
    for change in "${CHANGES[@]}"; do
      echo "   - $change"
    done
    HELM_ACTION="upgrade"

    # -----------------------------------------------------------------------
    # UPGRADE STRATEGY: scale-to-0, delete secondary PVCs, Helm bootstrap
    #
    # Uses galera_verify_bootstrap_safe() and galera_delete_secondary_pvcs()
    # from utils/database.sh for shared logic with the health monitor.
    #
    # Why scale-to-0? All config/image changes take effect on restart.
    # Why delete secondary PVCs? Eliminates stale grastate.dat where
    # safe_to_bootstrap: 1 causes Bitnami to create standalone clusters.
    # Why two Helm upgrades? galera-0 must bootstrap alone (forceBootstrap)
    # before secondaries start (forceBootstrap=false).
    #
    # Sequence:
    #   1. Pre-check: verify galera-0 is safe to bootstrap from
    #   2. Scale to 0 (OrderedReady = galera-0 shuts down last)
    #   3. Delete secondary PVCs
    #   4. Helm upgrade: forceBootstrap=true, replicaCount=1
    #   5. Wait for galera-0 Ready
    #   6. Helm upgrade: forceBootstrap=false, replicaCount=$DB_REPLICAS
    #   7. OrderedReady handles sequential secondary startup + SST
    # -----------------------------------------------------------------------

    # Step 1: Pre-check
    echo ""
    echo "Step 1: Pre-flight verification..."
    if ! galera_verify_bootstrap_safe "$DB_DEPLOYMENT_NAME" "$DEPLOY_NAMESPACE"; then
      echo "ABORT: galera-0 is not safe to bootstrap from"
      echo "   Manual intervention required before automated upgrade can proceed."
      exit 1
    fi

    # Step 2: Scale to 0
    echo ""
    echo "Step 2: Scaling $DB_DEPLOYMENT_NAME to 0 replicas..."
    oc scale sts/$DB_DEPLOYMENT_NAME --replicas=0 -n "$DEPLOY_NAMESPACE"

    SCALE_WAIT=0
    while [[ $SCALE_WAIT -lt 180 ]]; do
      REMAINING_PODS=$(oc get pods -l "app.kubernetes.io/name=$DB_DEPLOYMENT_NAME" \
        -n "$DEPLOY_NAMESPACE" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
      if [[ -z "$REMAINING_PODS" ]]; then
        echo "   All pods terminated"
        break
      fi
      sleep 5
      SCALE_WAIT=$((SCALE_WAIT + 5))
      if [[ $((SCALE_WAIT % 30)) -eq 0 ]]; then
        echo "   Still waiting... ${SCALE_WAIT}s elapsed (pods: $REMAINING_PODS)"
      fi
    done
    if [[ $SCALE_WAIT -ge 180 ]]; then
      echo "Warning: pods did not terminate within 180s, continuing..."
    fi

    # Step 3: Delete secondary PVCs
    echo ""
    echo "Step 3: Deleting secondary PVCs..."
    galera_delete_secondary_pvcs "$DB_DEPLOYMENT_NAME" "$DB_REPLICAS" "$DEPLOY_NAMESPACE"

    # Step 4: Helm upgrade -- bootstrap galera-0 alone
    echo ""
    echo "Step 4: Bootstrapping galera-0 (forceBootstrap=true, replicaCount=1)..."
    helm_upgrade_response=$(helm upgrade $DB_DEPLOYMENT_NAME \
      oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
      --set image.registry=$RESOLVED_IMAGE_REGISTRY \
      --set image.repository=$RESOLVED_IMAGE_REPOSITORY \
      --set image.tag=$RESOLVED_IMAGE_TAG \
      --set global.security.allowInsecureImages=true \
      --set global.imagePullSecrets[0].name="${ARTIFACTORY_PULL_SECRET}" \
      --set existingSecret=$DB_DEPLOYMENT_NAME \
      --set galera.bootstrap.forceBootstrap=true \
      --set galera.bootstrap.forceSafeToBootstrap=true \
      --set galera.bootstrap.bootstrapFromNode=0 \
      --set replicaCount=1 \
      --set startupProbe.enabled=true \
      --set startupProbe.initialDelaySeconds=120 \
      --set startupProbe.periodSeconds=15 \
      --set startupProbe.timeoutSeconds=5 \
      --set startupProbe.failureThreshold=80 \
      --set readinessProbe.enabled=true \
      --set readinessProbe.initialDelaySeconds=30 \
      --set readinessProbe.periodSeconds=15 \
      --set readinessProbe.timeoutSeconds=5 \
      --set livenessProbe.enabled=true \
      --set livenessProbe.initialDelaySeconds=180 \
      --set livenessProbe.periodSeconds=30 \
      --set livenessProbe.timeoutSeconds=10 \
      --set livenessProbe.failureThreshold=6 \
      --reuse-values 2>&1)

    if [[ $? -ne 0 ]]; then
      echo "Helm upgrade (bootstrap) failed:"
      echo "$helm_upgrade_response"
      exit 1
    fi

    # Step 5: Wait for galera-0 Ready
    echo "Waiting for ${DB_DEPLOYMENT_NAME}-0 to bootstrap..."
    READY_ATTEMPTS=0
    MAX_READY_ATTEMPTS=60
    while [[ $READY_ATTEMPTS -lt $MAX_READY_ATTEMPTS ]]; do
      POD_READY=$(oc get pod "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
      if [[ "$POD_READY" == "True" ]]; then
        echo "   ${DB_DEPLOYMENT_NAME}-0 is Ready (bootstrapped as primary)"
        break
      fi
      sleep 10
      READY_ATTEMPTS=$((READY_ATTEMPTS + 1))
      if [[ $((READY_ATTEMPTS % 6)) -eq 0 ]]; then
        echo "   Still waiting... $((READY_ATTEMPTS * 10))s elapsed"
      fi
    done
    if [[ $READY_ATTEMPTS -eq $MAX_READY_ATTEMPTS ]]; then
      echo "${DB_DEPLOYMENT_NAME}-0 failed to bootstrap within 600s"
      exit 1
    fi

    # Step 6: Helm upgrade -- disable bootstrap, scale to target
    if [[ "$DB_REPLICAS" -gt 1 ]]; then
      echo ""
      echo "Step 6: Scaling to $DB_REPLICAS replicas (forceBootstrap=false)..."
      helm upgrade $DB_DEPLOYMENT_NAME \
        oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
        --set galera.bootstrap.forceBootstrap=false \
        --set galera.bootstrap.forceSafeToBootstrap=false \
        --set replicaCount=$DB_REPLICAS \
        --set extraFlags="" \
        --set mariadbd.extraFlags="" \
        --reuse-values

      if [[ $? -ne 0 ]]; then
        echo "Helm upgrade (scale) failed"
        exit 1
      fi
      echo "Helm upgrade submitted -- secondaries will SST from galera-0"
    else
      # Single replica: just disable bootstrap
      echo ""
      echo "Step 6: Disabling bootstrap (single-replica cluster)..."
      helm upgrade $DB_DEPLOYMENT_NAME \
        oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
        --set galera.bootstrap.forceBootstrap=false \
        --set galera.bootstrap.forceSafeToBootstrap=false \
        --set replicaCount=1 \
        --reuse-values
    fi
  fi

else
  echo "Helm release $DB_DEPLOYMENT_NAME NOT FOUND -- performing fresh install..."
  HELM_ACTION="install"

  # Fresh install: bootstrap galera-0 first (replicaCount=1), then scale up.
  # OrderedReady ensures galera-0 starts and bootstraps before any secondaries.
  helm install $DB_DEPLOYMENT_NAME \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
    --set image.registry=$RESOLVED_IMAGE_REGISTRY \
    --set image.repository=$RESOLVED_IMAGE_REPOSITORY \
    --set image.tag=$RESOLVED_IMAGE_TAG \
    --set image.pullPolicy=Always \
    --set global.security.allowInsecureImages=true \
    --set global.imagePullSecrets[0].name="${ARTIFACTORY_PULL_SECRET:-artifactory-m950-learning}" \
    --set podManagementPolicy=OrderedReady \
    --set galera.bootstrap.forceSafeToBootstrap=true \
    --set galera.bootstrap.forceBootstrap=true \
    --set galera.bootstrap.bootstrapFromNode=0 \
    --set image.debug=false \
    --set existingSecret=$DB_DEPLOYMENT_NAME \
    --set db.user=$DB_USER \
    --set db.name=$DB_NAME \
    --set replicaCount=1 \
    --set persistence.size=10Gi \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=256Mi \
    --set startupProbe.enabled=true \
    --set startupProbe.initialDelaySeconds=120 \
    --set startupProbe.periodSeconds=15 \
    --set startupProbe.timeoutSeconds=5 \
    --set startupProbe.failureThreshold=80 \
    --set readinessProbe.enabled=true \
    --set readinessProbe.initialDelaySeconds=30 \
    --set readinessProbe.periodSeconds=15 \
    --set readinessProbe.timeoutSeconds=5 \
    --set livenessProbe.enabled=true \
    --set livenessProbe.initialDelaySeconds=180 \
    --set livenessProbe.periodSeconds=30 \
    --set livenessProbe.timeoutSeconds=10 \
    --set livenessProbe.failureThreshold=6 \
    --set extraVolumes[0].name=prestop-script \
    --set extraVolumes[0].configMap.name=${DB_DEPLOYMENT_NAME}-prestop-script \
    --set extraVolumeMounts[0].name=prestop-script \
    --set extraVolumeMounts[0].mountPath=/usr/local/bin/prestop.sh \
    --set extraVolumeMounts[0].subPath=mariadb-prestop.sh \
    --set extraVolumeMounts[0].readOnly=true \
    --set lifecycle.preStop.exec.command[0]="/bin/sh" \
    --set lifecycle.preStop.exec.command[1]="-c" \
    --set extraFlags="" \
    --set mariadbd.extraFlags="" \
    --set lifecycle.preStop.exec.command[2]="/usr/local/bin/prestop.sh"

  echo "Helm install completed with replicaCount=1 (bootstrap)"

  # Wait for galera-0 to bootstrap and become Ready
  echo "Waiting for ${DB_DEPLOYMENT_NAME}-0 to bootstrap..."
  READY_ATTEMPTS=0
  MAX_READY_ATTEMPTS=60
  while [[ $READY_ATTEMPTS -lt $MAX_READY_ATTEMPTS ]]; do
    POD_READY=$(oc get pod "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$POD_READY" == "True" ]]; then
      echo "${DB_DEPLOYMENT_NAME}-0 is Ready (bootstrapped as primary)"
      break
    fi
    sleep 10
    READY_ATTEMPTS=$((READY_ATTEMPTS + 1))
    if [[ $((READY_ATTEMPTS % 6)) -eq 0 ]]; then
      echo "   Still waiting... $((READY_ATTEMPTS * 10))s elapsed"
    fi
  done
  if [[ $READY_ATTEMPTS -eq $MAX_READY_ATTEMPTS ]]; then
    echo "${DB_DEPLOYMENT_NAME}-0 failed to bootstrap within 600s"
    exit 1
  fi

  # Scale to target replica count if > 1
  if [[ "$DB_REPLICAS" -gt 1 ]]; then
    echo "Scaling to $DB_REPLICAS replicas (secondaries join via IST/SST)..."
    helm upgrade $DB_DEPLOYMENT_NAME \
      oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
      --set galera.bootstrap.forceBootstrap=false \
      --set galera.bootstrap.forceSafeToBootstrap=false \
      --set replicaCount=$DB_REPLICAS \
      --reuse-values

    if [[ $? -ne 0 ]]; then
      echo "Failed to scale to $DB_REPLICAS replicas"
      exit 1
    fi
    echo "Helm upgrade submitted -- scaling to $DB_REPLICAS replicas"
  fi
fi

# =============================================================================
# TIER 4: Post-deploy -- patches, health verification, data checks
# =============================================================================
echo ""
echo "======================================================================="
echo "TIER 4: Post-deploy Verification"
echo "======================================================================="

log_debug "DEBUG: USE_ARTIFACTORY=$USE_ARTIFACTORY"
log_debug "DEBUG: HELM_REPO=$HELM_REPO"
log_debug "DEBUG: ARTIFACTORY_REGISTRY=$ARTIFACTORY_REGISTRY"
log_debug "DEBUG: MARIADB_IMAGE=$MARIADB_IMAGE"
log_debug "DEBUG: RESOLVED_FULL_IMAGE=$RESOLVED_FULL_IMAGE"
log_debug "DEBUG: RESOLVED_IMAGE_REPOSITORY=$RESOLVED_IMAGE_REPOSITORY"
log_debug "DEBUG: RESOLVED_IMAGE_TAG=$RESOLVED_IMAGE_TAG"

# -------------------------------------------------------------------------
# JSON patches -- idempotent safety net for preStop hooks and image overrides
# Applied after Helm to catch any drift between Helm values and live state.
# -------------------------------------------------------------------------
json_path_exists() {
  local path=$1
  if ! oc get statefulset $DB_DEPLOYMENT_NAME -o jsonpath="$path" &> /dev/null; then
    return 1
  fi
  return 0
}

patches=(
  "{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"$RESOLVED_FULL_IMAGE\"}"
  "{\"op\": \"replace\", \"path\": \"/spec/template/spec/initContainers/0/image\", \"value\": \"$RESOLVED_FULL_IMAGE\"}"
  '{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "prestop-script", "configMap": {"name": "mariadb-galera-prestop-script"}}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "prestop-script", "mountPath": "/usr/local/bin/prestop.sh", "subPath": "mariadb-prestop.sh", "readOnly": true}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/lifecycle", "value": {}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/lifecycle/preStop", "value": {"exec": {"command": ["/bin/sh", "-c", "/usr/local/bin/prestop.sh"]}}}'
)

paths=(
  '.spec.template.spec.containers[0].image'
  '.spec.template.spec.initContainers[0].image'
  '{.spec.template.spec.volumes[?(@.name=="prestop-script")]}'
  '{.spec.template.spec.containers[0].volumeMounts[?(@.name=="prestop-script")]}'
  '{.spec.template.spec.containers[0].lifecycle}'
  '{.spec.template.spec.containers[0].lifecycle.preStop}'
)

if oc get statefulset $DB_DEPLOYMENT_NAME &> /dev/null; then
  echo "Applying JSON patch safety net from $PATCH_FILE"

  patches_to_apply=()
  for i in "${!paths[@]}"; do
    if ! json_path_exists "${paths[$i]}"; then
      patches_to_apply+=("${patches[$i]}")
    fi
  done

  if [ ${#patches_to_apply[@]} -gt 0 ]; then
    echo "Applying patches to StatefulSet $DB_DEPLOYMENT_NAME..."
    oc patch statefulset $DB_DEPLOYMENT_NAME --type=json -p "[${patches_to_apply[*]}]"
  else
    echo "All patches already applied. No changes needed."
  fi
fi

sleep 10

# Ensure PVC retention policy protects data during scaling/deletion
oc patch statefulset $DB_DEPLOYMENT_NAME \
  -p '{"spec":{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"Retain","whenScaled":"Retain"}}}' 2>/dev/null || true

echo "All patches applied successfully"

# -------------------------------------------------------------------------
# Verify StatefulSet template has correct image
# -------------------------------------------------------------------------
echo "Verifying StatefulSet template configuration..."
STS_TEMPLATE_IMAGE=$(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "   StatefulSet template image: $STS_TEMPLATE_IMAGE"

if [[ "$STS_TEMPLATE_IMAGE" == "docker.io/"* ]]; then
  echo "ERROR: StatefulSet template still has docker.io prefix!"
  exit 1
elif [[ "$STS_TEMPLATE_IMAGE" == "$RESOLVED_FULL_IMAGE" ]]; then
  echo "StatefulSet template matches expected image configuration"
else
  echo "Warning: StatefulSet template image differs from expected"
  echo "   Expected: $RESOLVED_FULL_IMAGE"
  echo "   Actual: $STS_TEMPLATE_IMAGE"
fi

# -------------------------------------------------------------------------
# Wait for rollout and verify Galera cluster health
# -------------------------------------------------------------------------
if [[ "$HELM_ACTION" != "skip" ]]; then
  echo "Waiting for StatefulSet rollout to complete..."
  oc rollout status sts/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" --timeout=600s
  if [[ $? -ne 0 ]]; then
    echo "StatefulSet rollout did not complete within 600s"
    exit 1
  fi
  echo "StatefulSet rollout complete"
fi

# Wait for Galera sync using existing utility (checks per-pod Synced + cluster_size)
wait_for_galera_sync "$DB_DEPLOYMENT_NAME" 30 10 "$DB_REPLICAS"

# =============================================================================
# EXPAND PVCs DURING SCALE-UP
# =============================================================================
# Monitor for new PVCs and expand to target size from CSV
# Note: Expansion completion wait is disabled to reduce deployment time
# Storage expansion happens asynchronously and completes before capacity is needed
expand_mariadb_galera_pvcs "$DB_DEPLOYMENT_NAME" "$DB_REPLICAS" "$DEPLOY_NAMESPACE"

# Split-brain detection: verify all pods share the same cluster UUID
echo "Verifying Galera cluster consistency (split-brain detection)..."
check_galera_cluster_health "app.kubernetes.io/name=$DB_DEPLOYMENT_NAME" "$DEPLOY_NAMESPACE" "$DB_REPLICAS"
GALERA_HEALTH=$?
if [[ $GALERA_HEALTH -eq 2 ]]; then
  echo "SPLIT-BRAIN DETECTED!"
  echo "   Pods have divergent cluster UUIDs -- data integrity is at risk."
  echo "   Manual recovery steps:"
  echo "   1. oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1   (keep galera-0)"
  echo "   2. Delete PVCs for secondary nodes (data-$DB_DEPLOYMENT_NAME-1, -2, ...)"
  echo "   3. Verify galera-0 has production data: SELECT COUNT(*) FROM user;"
  echo "   4. oc scale sts/$DB_DEPLOYMENT_NAME --replicas=$DB_REPLICAS"
  exit 1
elif [[ $GALERA_HEALTH -eq 1 ]]; then
  echo "Some Galera pods are unhealthy. Check pod logs for details."
  exit 1
fi
echo "Galera cluster is consistent -- no split-brain detected"

# -------------------------------------------------------------------------
# Verify pods are using correct image
# -------------------------------------------------------------------------
echo "Verifying pods are using correct image..."
POD_NAMES=$(oc get pods -l app.kubernetes.io/name=$DB_DEPLOYMENT_NAME -o jsonpath='{.items[*].metadata.name}')

if [ -z "$POD_NAMES" ]; then
  echo "Warning: No pods found for verification"
else
  IMAGE_VERIFICATION_FAILED=false
  for POD_NAME in $POD_NAMES; do
    ACTUAL_IMAGE=$(oc get pod $POD_NAME -o jsonpath='{.spec.containers[0].image}')
    echo "   Pod $POD_NAME: $ACTUAL_IMAGE"

    if [[ "$ACTUAL_IMAGE" == "docker.io/"* ]]; then
      echo "   ERROR: Pod still has docker.io prefix in image!"
      IMAGE_VERIFICATION_FAILED=true
    elif [[ "$ACTUAL_IMAGE" == "$RESOLVED_FULL_IMAGE" ]]; then
      echo "   Image matches expected configuration"
    else
      echo "   Warning: Image does not match expected: $RESOLVED_FULL_IMAGE"
    fi
  done

  if [ "$IMAGE_VERIFICATION_FAILED" = true ]; then
    echo "Image verification failed - pods are using incorrect images"
  fi
fi

# -------------------------------------------------------------------------
# Verify database is online and contains Moodle data
# -------------------------------------------------------------------------
echo "Checking if the database is online and contains expected Moodle data..."
ATTEMPTS=0
WAIT_TIME=10
MAX_ATTEMPTS=60

DB_POD_NAME=""
until [ -n "$DB_POD_NAME" ]; do
  ATTEMPTS=$(( $ATTEMPTS + 1 ))
  DB_POD_NAME=$(oc get pods -l app.kubernetes.io/name=$DB_DEPLOYMENT_NAME -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')
  if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
    echo "Timeout waiting for the pod to have status.phase:Running. Exiting..."
    exit 1
  fi
  if [ -z "$DB_POD_NAME" ]; then
    echo "Waiting for the database pod to be ready... $(($ATTEMPTS * $WAIT_TIME)) seconds..."
    sleep $WAIT_TIME
  fi
done

echo "Database pod name: $DB_POD_NAME has been found and is running."

ATTEMPTS=0
CURRENT_USER_COUNT=0

until [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
  ATTEMPTS=$(( $ATTEMPTS + 1 ))
  echo "Waiting for database to come online... $(($ATTEMPTS * $WAIT_TIME)) seconds..."

  DB_QUERY="USE $DB_NAME; SELECT COUNT(*) FROM user;"
  echo "Connecting to database (as $DB_USER) with query: $DB_QUERY"
  OUTPUT=$(oc exec $DB_POD_NAME -- bash -c "mariadb -u'$DB_USER' -p'$DB_PASSWORD' -e 'USE $DB_NAME; SELECT COUNT(*) FROM user;'" 2>&1)

  if echo "$OUTPUT" | grep -qi "error"; then
    echo "Database error: $OUTPUT"
  fi

  if echo "$OUTPUT" | grep -qi "COUNT"; then
    CURRENT_USER_COUNT=$(echo "$OUTPUT" | grep -oP '\d+')
  fi

  if [ $CURRENT_USER_COUNT -gt 0 ]; then
    echo "Database is online and contains $CURRENT_USER_COUNT users."
    break
  else
    echo "Database is offline. Attempt $ATTEMPTS out of $MAX_ATTEMPTS."
    sleep $WAIT_TIME
  fi
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
  echo "Timeout waiting for the database to be online. Exiting..."
  exit 1
fi

# Verify Artifactory image pull secrets are configured
echo "Verifying Artifactory access for MariaDB deployment..."
if ensure_image_pull_secrets "statefulset" "$DB_DEPLOYMENT_NAME"; then
  echo "MariaDB StatefulSet has Artifactory access confirmed"
else
  echo "MariaDB StatefulSet may have imagePullSecrets issues"
fi

echo ""
echo "======================================================================="
echo "$DB_NAME Database deployment is complete."
echo "======================================================================="
