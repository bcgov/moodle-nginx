#!/bin/bash
#==============================================================================
# deploy-mariadb-galera.sh
#==============================================================================
# PURPOSE:
#   Deploy MariaDB Galera cluster to OpenShift with 3-node replication for
#   high availability. Manages StatefulSet deployment, ConfigMaps, PVCs, and
#   custom preStop hooks for graceful shutdown.
#
# ARCHITECTURE:
#   - 3-node StatefulSet for multi-master replication
#   - Custom my.cnf configuration via ConfigMap
#   - Helm-based deployment with Artifactory image support
#   - PreStop hook prevents split-brain scenarios during pod shutdown
#   - Persistent volumes for each pod (data/, temp/, backups/)
#
# QUICK CONFIG:
#   DB_DEPLOYMENT_NAME       - StatefulSet name (default: mariadb-galera)
#   USE_ARTIFACTORY          - Pull from Artifactory vs. public registry
#   MARIADB_IMAGE            - Image name:tag (resolved via helm-image-resolver.sh)
#   GALERA_CLUSTER_BOOTSTRAP - Bootstrap mode (default: no)
#
# USAGE:
#   # Standard deployment
#   export DB_DEPLOYMENT_NAME="mariadb-galera"
#   ./openshift/scripts/deploy-mariadb-galera.sh
#
#   # Bootstrap new cluster (first deployment only)
#   export GALERA_CLUSTER_BOOTSTRAP="yes"
#   ./openshift/scripts/deploy-mariadb-galera.sh
#
# RELATED DOCS:
#   - Architecture: ../../docs/galera-monitoring-solution.md
#   - Troubleshooting: ../../docs/manual-galera-troubleshooting.md
#   - Configuration: ../../config/mariadb/my.cnf
#   - Helm Values: ../../config/mariadb/galera-values.yaml
#   - PreStop Patch: ../../config/mariadb/mariadb-galera-prestop-patch.json
#==============================================================================

# Source the utility script
source ./openshift/scripts/_utils.sh

# =============================================================================
# FAILURE CLEANUP — trap handler for safe rollback on exit 1
# =============================================================================
# Tracks deployment phase so cleanup knows what to undo.
# Environment-aware:
#   Dev/Test: restore previous replica count (best-effort site recovery)
#   Prod:     leave site in maintenance mode for manual review
# Always:     restore RollingUpdate strategy + BOOTSTRAP=no if we changed them
# =============================================================================
GALERA_DEPLOY_PHASE="init"      # Tracks where we are in the deployment
PRE_DEPLOY_REPLICAS=""          # Captured before scale-down

galera_cleanup() {
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    return 0
  fi

  echo ""
  echo "🔴 ============================================="
  echo "🔴 GALERA DEPLOYMENT FAILED (phase: $GALERA_DEPLOY_PHASE)"
  echo "🔴 ============================================="

  # Always restore safe template state if we touched it
  if [[ "$GALERA_DEPLOY_PHASE" =~ ^(ondelete|bootstrap|env-flip|scale-up|refresh|restore)$ ]]; then
    echo "🔧 Cleanup: restoring safe StatefulSet template state..."

    # Restore BOOTSTRAP=no to prevent accidental bootstrap on next pod restart
    oc set env statefulset/$DB_DEPLOYMENT_NAME \
      "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
      "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
      -n "$DEPLOY_NAMESPACE" 2>/dev/null || true

    # Restore RollingUpdate strategy (OnDelete left in place is dangerous)
    oc patch statefulset/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" \
      -p '{"spec":{"updateStrategy":{"type":"RollingUpdate"}}}' 2>/dev/null || true

    echo "   ✅ Template restored: BOOTSTRAP=no, RollingUpdate strategy"
  fi

  # Environment-aware recovery
  if [[ "$DEPLOY_NAMESPACE" == *"-prod"* ]]; then
    # Production: leave in maintenance mode for manual review
    echo ""
    echo "🔴 PRODUCTION — site left in maintenance mode for manual review."
    echo "   Database may be partially deployed. Check cluster state:"
    echo "   oc get pods -l app.kubernetes.io/name=$DB_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE"
    echo "   oc get sts/$DB_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE -o jsonpath='{.spec.replicas}'"
    echo ""
    echo "   To restore manually:"
    echo "   1. Verify galera-0 PVC has production data"
    echo "   2. oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1 -n $DEPLOY_NAMESPACE"
    echo "   3. Wait for galera-0 Ready, then scale to $DB_REPLICAS incrementally"
  else
    # Dev/Test: attempt best-effort recovery
    if [[ -n "$PRE_DEPLOY_REPLICAS" && "$PRE_DEPLOY_REPLICAS" -gt 0 ]]; then
      echo ""
      echo "🔄 Dev/Test — attempting to restore previous state ($PRE_DEPLOY_REPLICAS replicas)..."
      oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1 -n "$DEPLOY_NAMESPACE" 2>/dev/null || true
      echo "   ⏳ Waiting for galera-0..."
      local restore_wait=0
      while [[ $restore_wait -lt 30 ]]; do
        local pod_ready
        pod_ready=$(oc get pod "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE" \
          -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        if [[ "$pod_ready" == "True" ]]; then
          echo "   ✅ galera-0 restored"
          # Scale back to previous count if > 1
          if [[ "$PRE_DEPLOY_REPLICAS" -gt 1 ]]; then
            oc scale sts/$DB_DEPLOYMENT_NAME --replicas=$PRE_DEPLOY_REPLICAS -n "$DEPLOY_NAMESPACE" 2>/dev/null || true
            echo "   📈 Scaled to $PRE_DEPLOY_REPLICAS (previous count)"
          fi
          break
        fi
        sleep 10
        restore_wait=$((restore_wait + 1))
      done
      if [[ $restore_wait -eq 30 ]]; then
        echo "   ❌ Could not restore galera-0 — manual intervention required"
      fi
    else
      echo "⚠️  No previous replica state to restore (was 0 or unknown)"
    fi
  fi

  echo ""
  echo "🔴 Deploy script exiting with code $exit_code"
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

# Preflight: validate DB_REPLICAS matches the sizing CSV
SIZING_CSV="./openshift/${DEPLOY_NAMESPACE}-sizing.csv"
if [[ -f "$SIZING_CSV" ]]; then
  CSV_POD_COUNT=$(awk -F',' '$1 == "'"$DB_DEPLOYMENT_NAME"'" { print $3 }' "$SIZING_CSV" | tr -d ' ')
  if [[ -n "$CSV_POD_COUNT" && "$CSV_POD_COUNT" != "$DB_REPLICAS" ]]; then
    echo "❌ CONFIG MISMATCH: DB_REPLICAS=$DB_REPLICAS but $SIZING_CSV has PodCount=$CSV_POD_COUNT"
    echo "   The deploy script builds gcomm:// for $DB_REPLICAS nodes, but right-sizing.sh"
    echo "   will later scale to $CSV_POD_COUNT — extra nodes get an incomplete cluster address."
    echo "   Fix: set DB_REPLICAS=$CSV_POD_COUNT in GitHub Environment or example.env"
    exit 1
  fi
  echo "✅ DB_REPLICAS=$DB_REPLICAS matches sizing CSV ($SIZING_CSV)"
else
  echo "⚠️  Sizing CSV not found: $SIZING_CSV — skipping replica count validation"
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
    echo "❌ Helm environment validation failed. Please check your environment variables."
    exit 1
fi

show_artifactory_status

# Resolve MariaDB image configuration
if ! resolve_helm_image "MARIADB_IMAGE"; then
    echo "❌ Failed to resolve MARIADB_IMAGE configuration"
    exit 1
fi

echo "🐳 Using MariaDB image: ${RESOLVED_FULL_IMAGE}"

PATCH_FILE="config/mariadb/mariadb-galera-prestop-patch.json"

# Ensure we're using custom config for the database
echo "Creating ConfigMap mariadb-galera-configuration..."
create_or_update_configmap "mariadb-galera-configuration" "./config/mariadb/my.cnf"
oc label configmap mariadb-galera-configuration app.kubernetes.io/managed-by=Helm --overwrite
oc annotate configmap mariadb-galera-configuration meta.helm.sh/release-name=mariadb-galera --overwrite
oc annotate configmap mariadb-galera-configuration meta.helm.sh/release-namespace="${DEPLOY_NAMESPACE}" --overwrite

# Create or update the ConfigMap from the prestop.sh script
create_or_update_configmap "${DB_DEPLOYMENT_NAME}-prestop-script" "mariadb-prestop.sh=./openshift/scripts/mariadb-prestop.sh"

# Check if the Helm deployment exists
if helm list -q | grep -q "^$DB_DEPLOYMENT_NAME$"; then
  echo "$DB_DEPLOYMENT_NAME installation found"

  # =========================================================================
  # GRACEFUL INCREMENTAL SCALE-DOWN
  # =========================================================================
  # With podManagementPolicy: Parallel, scaling to 0 in one step terminates
  # all pods simultaneously — safe_to_bootstrap lands on a random node.
  # Scaling one-at-a-time guarantees galera-0 is last to leave, giving it
  # safe_to_bootstrap=1 in its PVC grastate.dat. Defense-in-depth for the
  # OnDelete bootstrap pattern that follows.
  # =========================================================================
  CURRENT_REPLICAS=$(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.spec.replicas}' 2>/dev/null || echo "0")
  PRE_DEPLOY_REPLICAS="$CURRENT_REPLICAS"  # Capture for rollback
  GALERA_DEPLOY_PHASE="scale-down"
  if [[ "${CURRENT_REPLICAS:-0}" -gt 1 ]]; then
    # Multi-replica: scale secondaries down first, leaving galera-0 last
    echo "📉 Scaling $DB_DEPLOYMENT_NAME to 1 (removing secondaries)..."
    for SCALE_TARGET in $(seq $((CURRENT_REPLICAS - 1)) -1 1); do
      echo "   📉 $((SCALE_TARGET + 1)) → $SCALE_TARGET replicas (removing ${DB_DEPLOYMENT_NAME}-${SCALE_TARGET})..."
      oc scale sts/$DB_DEPLOYMENT_NAME --replicas=$SCALE_TARGET

      # Wait for pod count to reach target
      ATTEMPTS=0
      while true; do
        ACTUAL=$(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.status.replicas}' 2>/dev/null)
        [[ "${ACTUAL:-0}" -le "$SCALE_TARGET" ]] && break
        sleep 10
        ATTEMPTS=$((ATTEMPTS + 1))
        if [[ $ATTEMPTS -ge 60 ]]; then
          echo "   ❌ Timeout scaling to $SCALE_TARGET replicas"
          exit 1
        fi
      done
    done

    # =========================================================================
    # VALIDATE: galera-0 sees itself as sole primary before final shutdown.
    # wsrep_cluster_size=1 confirms all departures were processed by Galera.
    # Without this check, we scale to 0 while Galera still thinks peers exist,
    # which can leave safe_to_bootstrap=0 in grastate.dat.
    # (FORCE_SAFETOBOOTSTRAP=yes in step 2 handles this anyway, but belt+suspenders.)
    # =========================================================================
    echo "🔍 Validating galera-0 is sole primary before shutdown..."
    VALIDATION_ATTEMPTS=0
    MAX_VALIDATION_ATTEMPTS=18  # 3 minutes
    while [[ $VALIDATION_ATTEMPTS -lt $MAX_VALIDATION_ATTEMPTS ]]; do
      CLUSTER_SIZE=$(oc exec "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE" -- \
        bash -c "mariadb -u'root' -p'$DB_PASSWORD' -Nse \"SHOW STATUS LIKE 'wsrep_cluster_size';\" 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")
      STATE_COMMENT=$(oc exec "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE" -- \
        bash -c "mariadb -u'root' -p'$DB_PASSWORD' -Nse \"SHOW STATUS LIKE 'wsrep_local_state_comment';\" 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "")

      if [[ "$CLUSTER_SIZE" == "1" && "$STATE_COMMENT" == "Synced" ]]; then
        echo "   ✅ galera-0: wsrep_cluster_size=1, state=Synced (sole primary confirmed)"
        break
      fi
      echo "   ⏳ galera-0: cluster_size=${CLUSTER_SIZE:-?}, state=${STATE_COMMENT:-?} — waiting for departures to process..."
      sleep 10
      VALIDATION_ATTEMPTS=$((VALIDATION_ATTEMPTS + 1))
    done
    if [[ $VALIDATION_ATTEMPTS -eq $MAX_VALIDATION_ATTEMPTS ]]; then
      echo "   ⚠️  galera-0 didn't converge to sole primary (size=${CLUSTER_SIZE:-?})"
      echo "   Proceeding anyway — FORCE_SAFETOBOOTSTRAP=yes in step 2 covers this"
    fi

    # Now scale galera-0 to 0
    echo "   📉 1 → 0 replicas (shutting down galera-0)..."
    oc scale sts/$DB_DEPLOYMENT_NAME --replicas=0
    ATTEMPTS=0
    while true; do
      ACTUAL=$(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.status.replicas}' 2>/dev/null)
      [[ "${ACTUAL:-0}" -eq 0 ]] && break
      sleep 10
      ATTEMPTS=$((ATTEMPTS + 1))
      if [[ $ATTEMPTS -ge 60 ]]; then
        echo "   ❌ Timeout scaling to 0 replicas"
        exit 1
      fi
    done
    echo "✅ All pods terminated — galera-0 was last (sole primary, safe_to_bootstrap=1 in PVC)"

  elif [[ "${CURRENT_REPLICAS:-0}" -eq 1 ]]; then
    # Single replica: just scale to 0
    echo "📉 Scaling $DB_DEPLOYMENT_NAME to 0 (single replica)..."
    oc scale sts/$DB_DEPLOYMENT_NAME --replicas=0
    ATTEMPTS=0
    while true; do
      ACTUAL=$(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.status.replicas}' 2>/dev/null)
      [[ "${ACTUAL:-0}" -eq 0 ]] && break
      sleep 10
      ATTEMPTS=$((ATTEMPTS + 1))
      if [[ $ATTEMPTS -ge 60 ]]; then
        echo "   ❌ Timeout scaling to 0 replicas"
        exit 1
      fi
    done
    echo "✅ Single pod terminated"
  else
    echo "$DB_DEPLOYMENT_NAME already at 0 replicas"
  fi

  # Delete resources
  # First schedule PVC volumes for deletion (second and third of three - leave first [#0] for data replication)
  # data-mariadb-galera-0 (delete: data-mariadb-galera-1, data-mariadb-galera-2)
  echo "Deleting $DB_DEPLOYMENT_NAME replica PVCs..."
  # Gather related PVC names from OpenShift
  PVC_LIST=$(oc get pvc -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep "data-$DB_DEPLOYMENT_NAME-")

  # Loop through the PVCs and delete all except the primary (#0)
  for PVC in $PVC_LIST; do
    if [[ $PVC =~ ^data-$DB_DEPLOYMENT_NAME-[1-9][0-9]*$ ]]; then
      echo "Deleting PVC: $PVC"
      oc delete pvc $PVC
    fi
  done

  echo "Upgrading $DB_DEPLOYMENT_NAME..."

  # Capture the output of the helm upgrade command into a variable
  # Note: Keep replicas at 0 to prevent pods from starting before patches are applied
  helm_upgrade_response=$(helm upgrade $DB_DEPLOYMENT_NAME \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
    --set image.registry=$RESOLVED_IMAGE_REGISTRY \
    --set image.repository=$RESOLVED_IMAGE_REPOSITORY \
    --set image.tag=$RESOLVED_IMAGE_TAG \
    --set global.security.allowInsecureImages=true \
    --set global.imagePullSecrets[0].name="${ARTIFACTORY_PULL_SECRET}" \
    --set rootUser.password=$DB_PASSWORD \
    --set galera.mariabackup.password=$DB_PASSWORD \
    --set galera.bootstrap.forceBootstrap=false \
    --set galera.bootstrap.forceSafeToBootstrap=false \
    --set replicaCount=0 \
    --reuse-values 2>&1)
    # NOTE: podManagementPolicy is immutable on existing StatefulSets.
    # It is only set to OrderedReady on helm install (fresh deployments).

  # Output the response for debugging purposes
  # echo "$helm_upgrade_response"

  # Check if the helm upgrade command failed
  if [[ $? -ne 0 ]]; then
    echo "Helm upgrade failed with the following output:"
    echo "$helm_upgrade_response"
    exit 1
  fi

else
  echo "Helm deployment $DB_DEPLOYMENT_NAME NOT FOUND. Beginning deployment..."

  # Removed:
  # --set metrics.enabled=true \
  # --set metrics.serviceMonitor.enabled=true \
  # --set metrics.prometheusRules.enabled=false \
  # --set primary.persistence.accessModes={ReadWriteMany} \
  # --atomic \
  # Note: Start with replicas=0 to prevent pods from starting before patches are applied
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
    --set rootUser.password=$DB_PASSWORD \
    --set db.user=$DB_USER \
    --set db.password=$DB_PASSWORD \
    --set db.name=$DB_NAME \
    --set replicaCount=0 \
    --set persistence.size=10Gi \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=256Mi \
    --set readinessProbe.enabled=true \
    --set livenessProbe.enabled=true \
    --set startupProbe.enabled=true \
    --set galera.mariabackup.password=$DB_PASSWORD \
    --set galera.mariabackup.forcePassword=true \
    --set extraVolumes[0].name=prestop-script \
    --set extraVolumes[0].configMap.name=${DB_DEPLOYMENT_NAME}-prestop-script \
    --set extraVolumeMounts[0].name=prestop-script \
    --set extraVolumeMounts[0].mountPath=/usr/local/bin/prestop.sh \
    --set extraVolumeMounts[0].subPath=mariadb-prestop.sh \
    --set extraVolumeMounts[0].readOnly=true \
    --set lifecycle.preStop.exec.command[0]="/bin/sh" \
    --set lifecycle.preStop.exec.command[1]="-c" \
    --set lifecycle.preStop.exec.command[2]="/usr/local/bin/prestop.sh"
    #-f ./config/mariadb/galera-values.yaml

  echo "✅ Helm install completed with replicas=0 (pods will be started after patching)"
fi

log_debug "DEBUG: USE_ARTIFACTORY=$USE_ARTIFACTORY"
log_debug "DEBUG: HELM_REPO=$HELM_REPO"
log_debug "DEBUG: ARTIFACTORY_REGISTRY=$ARTIFACTORY_REGISTRY"
log_debug "DEBUG: MARIADB_IMAGE=$MARIADB_IMAGE"
log_debug "DEBUG: RESOLVED_IMAGE_REGISTRY=$RESOLVED_IMAGE_REGISTRY"
log_debug "DEBUG: RESOLVED_FULL_IMAGE=$RESOLVED_FULL_IMAGE"
log_debug "DEBUG: RESOLVED_IMAGE_REPOSITORY=$RESOLVED_IMAGE_REPOSITORY"
log_debug "DEBUG: RESOLVED_IMAGE_TAG=$RESOLVED_IMAGE_TAG"

# Function to check if a JSON path exists in the StatefulSet
json_path_exists() {
  local path=$1
  if ! oc get statefulset $DB_DEPLOYMENT_NAME -o jsonpath="$path" &> /dev/null; then
    echo "JSON path $path does not exist in the StatefulSet $DB_DEPLOYMENT_NAME"
    return 1
  fi
  return 0
}

# Define the patches to add custom container images
#  and a preStop hook to the StatefulSet
patches=(
  "{\"op\": \"replace\", \"path\": \"/spec/template/spec/containers/0/image\", \"value\": \"$RESOLVED_FULL_IMAGE\"}"
  "{\"op\": \"replace\", \"path\": \"/spec/template/spec/initContainers/0/image\", \"value\": \"$RESOLVED_FULL_IMAGE\"}"
  '{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "prestop-script", "configMap": {"name": "mariadb-galera-prestop-script"}}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "prestop-script", "mountPath": "/usr/local/bin/prestop.sh", "subPath": "mariadb-prestop.sh", "readOnly": true}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/lifecycle", "value": {}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/lifecycle/preStop", "value": {"exec": {"command": ["/bin/sh", "-c", "/usr/local/bin/prestop.sh"]}}}'
)

# Define the JSON paths to check if the patches have been applied
paths=(
  '.spec.template.spec.containers[0].image'
  '.spec.template.spec.initContainers[0].image'
  '{.spec.template.spec.volumes[?(@.name=="prestop-script")]}'
  '{.spec.template.spec.containers[0].volumeMounts[?(@.name=="prestop-script")]}'
  '{.spec.template.spec.containers[0].lifecycle}'
  '{.spec.template.spec.containers[0].lifecycle.preStop}'
)

# Patch the StatefulSet to add the preStop hook to every container
if oc get statefulset $DB_DEPLOYMENT_NAME &> /dev/null; then
  echo "Applying JSON patch from $PATCH_FILE"
  # cat $PATCH_FILE

  # Collect patches to apply
  patches_to_apply=()
  for i in "${!paths[@]}"; do
    if ! json_path_exists "${paths[$i]}"; then
      patches_to_apply+=("${patches[$i]}")
    fi
  done

  # Apply patches if there are any to apply
  if [ ${#patches_to_apply[@]} -gt 0 ]; then
    echo "Applying patches to StatefulSet $DB_DEPLOYMENT_NAME..."
    echo "Patches to apply: [${patches_to_apply[*]}]"
    oc patch statefulset $DB_DEPLOYMENT_NAME --type=json -p "[${patches_to_apply[*]}]"
  else
    echo "All patches already applied. No changes needed."
  fi
else
  echo "StatefulSet $DB_DEPLOYMENT_NAME not found. Skipping patch."
fi

sleep 10

# The value of "partition" determines which ordinals a change applies to
# Make sure to use a number bigger than the last ordinal for the
# StatefulSet, Also ensure PVC retention policy is set to "Retain"
oc patch statefulset $DB_DEPLOYMENT_NAME -p '{"spec":{"persistentVolumeClaimRetentionPolicy":{"whenDeleted":"Retain","whenScaled":"Retain"}, "updateStrategy":{"type":"RollingUpdate","rollingUpdate":{"partition":3}}}}'

echo "✅ All patches applied successfully"

# Verify StatefulSet template has correct image configuration
echo "🔍 Verifying StatefulSet template configuration..."
STS_TEMPLATE_IMAGE=$(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.spec.template.spec.containers[0].image}')
echo "   StatefulSet template image: $STS_TEMPLATE_IMAGE"

if [[ "$STS_TEMPLATE_IMAGE" == "docker.io/"* ]]; then
  echo "❌ ERROR: StatefulSet template still has docker.io prefix!"
  echo "   This indicates the image patches did not apply correctly"
  exit 1
elif [[ "$STS_TEMPLATE_IMAGE" == "$RESOLVED_FULL_IMAGE" ]]; then
  echo "✅ StatefulSet template matches expected image configuration"
else
  echo "⚠️  Warning: StatefulSet template image differs from expected"
  echo "   Expected: $RESOLVED_FULL_IMAGE"
  echo "   Actual: $STS_TEMPLATE_IMAGE"
fi

# =============================================================================
# GALERA CLUSTER STARTUP — OnDelete strategy bootstrap pattern
# =============================================================================
# PROBLEM:
#   helm upgrade --set replicaCount=0 renders MARIADB_GALERA_CLUSTER_ADDRESS=gcomm://
#   (empty — no members for 0 replicas). --reuse-values preserves this empty address.
#   Without correction, every pod bootstraps its own independent cluster (split-brain).
#   The Bitnami container requires CLUSTER_BOOTSTRAP=yes to add --wsrep-new-cluster;
#   PVC safe_to_bootstrap=1 alone is NOT sufficient to trigger bootstrap.
#
# SOLUTION (OnDelete + incremental scale-down):
#   Incremental scale-down above guarantees galera-0 has safe_to_bootstrap=1
#   in its PVC (defense-in-depth). OnDelete strategy allows flipping the
#   template from BOOTSTRAP=yes → BOOTSTRAP=no without restarting galera-0:
#
#   1. Switch to OnDelete update strategy (env changes don't auto-restart pods)
#   2. Set BOOTSTRAP=yes + real cluster address on the template
#   3. Scale to 1 — galera-0 bootstraps as primary with correct env
#   4. Flip template to BOOTSTRAP=no (galera-0 keeps running — OnDelete!)
#   5. Scale incrementally 2→N — secondaries get BOOTSTRAP=no and join galera-0
#   6. Delete galera-0 pod to pick up BOOTSTRAP=no env from refreshed template
#   7. Restore RollingUpdate strategy
#
# WHY OnDelete IS REQUIRED:
#   galera-0 needs BOOTSTRAP=yes, secondaries need BOOTSTRAP=no, but both
#   come from the same StatefulSet template. RollingUpdate would restart
#   galera-0 when we flip to BOOTSTRAP=no (killing the primary). OnDelete
#   lets the template change while galera-0 keeps running undisturbed.
# =============================================================================

# Build the full gcomm:// cluster address from replica count
HEADLESS_SVC="${DB_DEPLOYMENT_NAME}-headless.${DEPLOY_NAMESPACE}.svc.cluster.local"
WSREP_NODES=""
for i in $(seq 0 $((DB_REPLICAS - 1))); do
  [ -n "$WSREP_NODES" ] && WSREP_NODES="${WSREP_NODES},"
  WSREP_NODES="${WSREP_NODES}${DB_DEPLOYMENT_NAME}-${i}.${HEADLESS_SVC}"
done
GALERA_CLUSTER_ADDRESS="gcomm://${WSREP_NODES}"

# Step 1: Switch to OnDelete so env changes don't trigger rolling restarts
GALERA_DEPLOY_PHASE="ondelete"
echo "🔧 Switching to OnDelete update strategy..."
oc patch statefulset/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" \
  -p '{"spec":{"updateStrategy":{"type":"OnDelete"}}}'

# Step 2: Set bootstrap=yes + real cluster address for galera-0 startup
echo "📡 Setting Galera cluster address: $GALERA_CLUSTER_ADDRESS"
echo "🔧 Setting bootstrap=yes for galera-0 initial startup..."
oc set env statefulset/$DB_DEPLOYMENT_NAME \
  "MARIADB_GALERA_CLUSTER_ADDRESS=${GALERA_CLUSTER_ADDRESS}" \
  "MARIADB_GALERA_CLUSTER_BOOTSTRAP=yes" \
  "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=yes" \
  -n "$DEPLOY_NAMESPACE"

# Step 3: Scale to 1 — galera-0 bootstraps as primary
GALERA_DEPLOY_PHASE="bootstrap"
echo "📈 Scaling galera-0 as bootstrap node..."
oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1 -n "$DEPLOY_NAMESPACE"

# Wait for galera-0 to be Ready
echo "⏳ Waiting for ${DB_DEPLOYMENT_NAME}-0 to be Ready..."
READY_ATTEMPTS=0
MAX_READY_ATTEMPTS=60
while [[ $READY_ATTEMPTS -lt $MAX_READY_ATTEMPTS ]]; do
  POD_READY=$(oc get pod "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [[ "$POD_READY" == "True" ]]; then
    echo "✅ ${DB_DEPLOYMENT_NAME}-0 is Ready (bootstrapped as primary)"
    break
  fi
  sleep 10
  READY_ATTEMPTS=$((READY_ATTEMPTS + 1))
  if [[ $((READY_ATTEMPTS % 6)) -eq 0 ]]; then
    echo "   ⏳ Still waiting... $((READY_ATTEMPTS * 10))s elapsed"
  fi
done
if [[ $READY_ATTEMPTS -eq $MAX_READY_ATTEMPTS ]]; then
  echo "❌ ${DB_DEPLOYMENT_NAME}-0 failed to bootstrap within 600s"
  exit 1
fi

# Step 4: Flip template to BOOTSTRAP=no — galera-0 keeps running (OnDelete!)
GALERA_DEPLOY_PHASE="env-flip"
echo "🔧 Disabling bootstrap on template (galera-0 unaffected — OnDelete strategy)..."
oc set env statefulset/$DB_DEPLOYMENT_NAME \
  "MARIADB_GALERA_CLUSTER_BOOTSTRAP=no" \
  "MARIADB_GALERA_FORCE_SAFETOBOOTSTRAP=no" \
  -n "$DEPLOY_NAMESPACE"

# Step 5: Scale incrementally — secondaries join galera-0's cluster
GALERA_DEPLOY_PHASE="scale-up"
echo "📈 Scaling StatefulSet incrementally to $DB_REPLICAS replicas..."
for SCALE_TARGET in $(seq 2 $DB_REPLICAS); do
  CURRENT_REPLICAS=$(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.spec.replicas}' -n "$DEPLOY_NAMESPACE")
  if [[ "$CURRENT_REPLICAS" -ge "$SCALE_TARGET" ]]; then
    echo "   ✅ Already at $CURRENT_REPLICAS replicas (target: $SCALE_TARGET)"
    continue
  fi

  echo "   📈 Scaling to $SCALE_TARGET/$DB_REPLICAS replicas..."
  oc scale sts/$DB_DEPLOYMENT_NAME --replicas=$SCALE_TARGET -n "$DEPLOY_NAMESPACE"

  # Wait for the new pod to become Ready
  NEW_POD="${DB_DEPLOYMENT_NAME}-$((SCALE_TARGET - 1))"
  echo "   ⏳ Waiting for $NEW_POD to be Ready..."
  READY_ATTEMPTS=0
  MAX_READY_ATTEMPTS=60
  while [[ $READY_ATTEMPTS -lt $MAX_READY_ATTEMPTS ]]; do
    POD_READY=$(oc get pod "$NEW_POD" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$POD_READY" == "True" ]]; then
      echo "   ✅ $NEW_POD is Ready"
      break
    fi
    sleep 10
    READY_ATTEMPTS=$((READY_ATTEMPTS + 1))
    if [[ $((READY_ATTEMPTS % 6)) -eq 0 ]]; then
      WAITED=$((READY_ATTEMPTS * 10))
      echo "   ⏳ Still waiting for $NEW_POD... ${WAITED}s elapsed"
    fi
  done

  if [[ $READY_ATTEMPTS -eq $MAX_READY_ATTEMPTS ]]; then
    echo "   ❌ $NEW_POD failed to become Ready within 600s"
    # Check if it's CrashLooping due to safe_to_bootstrap
    RESTART_COUNT=$(oc get pod "$NEW_POD" -o jsonpath='{.status.containerStatuses[0].restartCount}' -n "$DEPLOY_NAMESPACE" 2>/dev/null || echo "0")
    if [[ "$RESTART_COUNT" -gt 1 ]]; then
      echo "   🔄 $NEW_POD is CrashLooping (restarts=$RESTART_COUNT) — attempting safe_to_bootstrap fix..."
      for attempt in $(seq 1 30); do
        if oc exec "$NEW_POD" -n "$DEPLOY_NAMESPACE" -- \
          sed -i 's/safe_to_bootstrap: 1/safe_to_bootstrap: 0/' /bitnami/mariadb/data/grastate.dat 2>/dev/null; then
          echo "   ✅ Reset safe_to_bootstrap on $NEW_POD (attempt $attempt)"
          echo "   ⏳ Waiting for $NEW_POD to recover..."
          sleep 30
          # Re-check readiness
          for recovery_check in $(seq 1 30); do
            POD_READY=$(oc get pod "$NEW_POD" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [[ "$POD_READY" == "True" ]]; then
              echo "   ✅ $NEW_POD recovered and is Ready"
              break 2
            fi
            sleep 10
          done
          echo "   ❌ $NEW_POD did not recover after safe_to_bootstrap fix."
          exit 1
        fi
        sleep 5
      done
    fi
    echo "❌ Failed to scale to $SCALE_TARGET replicas. Exiting..."
    exit 1
  fi
done

echo "✅ All $DB_REPLICAS replicas scaled and Ready."

GALERA_DEPLOY_PHASE="refresh"
# Step 6: Refresh galera-0 to pick up BOOTSTRAP=no env from the updated template.
# Under OnDelete, galera-0 still has BOOTSTRAP=yes from its original creation.
# With secondaries synced, galera-0 rejoins the cluster after restart.
if [[ $DB_REPLICAS -gt 1 ]]; then
  echo "🔄 Refreshing ${DB_DEPLOYMENT_NAME}-0 to pick up BOOTSTRAP=no env..."
  oc delete pod "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE"
  echo "   ⏳ Waiting for ${DB_DEPLOYMENT_NAME}-0 to rejoin cluster..."
  READY_ATTEMPTS=0
  MAX_READY_ATTEMPTS=60
  while [[ $READY_ATTEMPTS -lt $MAX_READY_ATTEMPTS ]]; do
    POD_READY=$(oc get pod "${DB_DEPLOYMENT_NAME}-0" -n "$DEPLOY_NAMESPACE" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$POD_READY" == "True" ]]; then
      echo "   ✅ ${DB_DEPLOYMENT_NAME}-0 rejoined cluster with BOOTSTRAP=no"
      break
    fi
    sleep 10
    READY_ATTEMPTS=$((READY_ATTEMPTS + 1))
    if [[ $((READY_ATTEMPTS % 6)) -eq 0 ]]; then
      echo "   ⏳ Still waiting... $((READY_ATTEMPTS * 10))s elapsed"
    fi
  done
  if [[ $READY_ATTEMPTS -eq $MAX_READY_ATTEMPTS ]]; then
    echo "   ❌ ${DB_DEPLOYMENT_NAME}-0 failed to rejoin cluster within 600s"
    exit 1
  fi
fi

# Step 7: Restore RollingUpdate strategy for normal operation
GALERA_DEPLOY_PHASE="restore"
echo "🔧 Restoring RollingUpdate update strategy..."
oc patch statefulset/$DB_DEPLOYMENT_NAME -n "$DEPLOY_NAMESPACE" \
  -p '{"spec":{"updateStrategy":{"type":"RollingUpdate"}}}'

# Split-brain detection: verify all pods share the same cluster UUID.
# wait_for_galera_sync checks per-pod state (Synced + cluster_size) but does
# NOT compare UUIDs across pods.  A split-brain can pass that check when each
# independent cluster reports Synced with size=1.
echo "🔍 Verifying Galera cluster consistency (split-brain detection)..."
check_galera_cluster_health "app.kubernetes.io/name=$DB_DEPLOYMENT_NAME" "$DEPLOY_NAMESPACE" "$DB_REPLICAS"
GALERA_HEALTH=$?
if [[ $GALERA_HEALTH -eq 2 ]]; then
  echo "🚨 SPLIT-BRAIN DETECTED after scale-up!"
  echo "   Pods have divergent cluster UUIDs — data integrity is at risk."
  echo "   The deployment will NOT proceed. Manual recovery steps:"
  echo "   1. oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1   (keep galera-0)"
  echo "   2. Delete PVCs for secondary nodes (data-$DB_DEPLOYMENT_NAME-1, -2, ...)"
  echo "   3. Verify galera-0 has production data: SELECT COUNT(*) FROM user;"
  echo "   4. oc scale sts/$DB_DEPLOYMENT_NAME --replicas=$DB_REPLICAS"
  exit 1
elif [[ $GALERA_HEALTH -eq 1 ]]; then
  echo "⚠️ Some Galera pods are unhealthy after scale-up."
  echo "   Deployment will NOT proceed. Check pod logs for details."
  exit 1
fi
echo "✅ Galera cluster is consistent — no split-brain detected."

echo "🔍 Verifying pods are using correct image..."
# Get all pod names for the StatefulSet
POD_NAMES=$(oc get pods -l app.kubernetes.io/name=$DB_DEPLOYMENT_NAME -o jsonpath='{.items[*].metadata.name}')

if [ -z "$POD_NAMES" ]; then
  echo "⚠️  Warning: No pods found for verification"
else
  IMAGE_VERIFICATION_FAILED=false
  for POD_NAME in $POD_NAMES; do
    ACTUAL_IMAGE=$(oc get pod $POD_NAME -o jsonpath='{.spec.containers[0].image}')
    echo "   Pod $POD_NAME: $ACTUAL_IMAGE"

    # Check if image matches expected (without docker.io prefix)
    if [[ "$ACTUAL_IMAGE" == "docker.io/"* ]]; then
      echo "   ❌ ERROR: Pod still has docker.io prefix in image!"
      IMAGE_VERIFICATION_FAILED=true
    elif [[ "$ACTUAL_IMAGE" == "$RESOLVED_FULL_IMAGE" ]]; then
      echo "   ✅ Image matches expected configuration"
    else
      echo "   ⚠️  Warning: Image does not match expected: $RESOLVED_FULL_IMAGE"
    fi
  done

  if [ "$IMAGE_VERIFICATION_FAILED" = true ]; then
    echo "❌ Image verification failed - pods are using incorrect images"
    echo "   This may indicate the StatefulSet needs to be manually scaled to 0 and back up"
    # Don't exit - let the database check proceed, but warn user
  fi
fi

echo "Checking if the database is online and contains expected Moodle data..."
ATTEMPTS=0
WAIT_TIME=10
MAX_ATTEMPTS=60 # wait up to 5 minutes

# Get the name of the first pod in the StatefulSet
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

  # Capture the output of the mariadb command
  DB_QUERY="USE $DB_NAME; SELECT COUNT(*) FROM user;"
  echo "Connecting to database (as $DB_USER) with query: $DB_QUERY"
  # OUTPUT=$(oc exec $DB_POD_NAME -- bash -c "mariadb -u'$DB_USER' -p'$DB_PASSWORD' -e '$DB_QUERY'" 2>&1)
  OUTPUT=$(oc exec $DB_POD_NAME -- bash -c "mariadb -u'$DB_USER' -p'$DB_PASSWORD' -e 'USE $DB_NAME; SELECT COUNT(*) FROM user;'" 2>&1)

  # Check if the output contains an error
  if echo "$OUTPUT" | grep -qi "error"; then
    echo "❌ Database error: $OUTPUT"
    # exit 1
  fi

  # Extract the user count from the output
  if echo "$OUTPUT" | grep -qi "COUNT"; then
    CURRENT_USER_COUNT=$(echo "$OUTPUT" | grep -oP '\d+')
  fi

  if [ $CURRENT_USER_COUNT -gt 0 ]; then
    echo "✔️ Database is online and contains $CURRENT_USER_COUNT users."
    # echo "Resetting master to avoid repolication issues..."
    # RESET=$(oc exec $DB_POD_NAME -- bash -c "mariadb -uroot -p'$DB_PASSWORD' -e 'RESET MASTER;'" 2>&1)
    # echo "Result: $RESET"
    break
  else
    echo "Database is offline. Attempt $ATTEMPTS out of $MAX_ATTEMPTS."
    sleep $WAIT_TIME
  fi
done

if [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; then
  echo "❌ Timeout waiting for the database to be online. Exiting..."
  exit 1
fi

# Verify Artifactory image pull secrets are configured (verification)
echo "Verifying Artifactory access for MariaDB deployment..."
if ensure_image_pull_secrets "statefulset" "$DB_DEPLOYMENT_NAME"; then
  echo "✅ MariaDB StatefulSet has Artifactory access confirmed"
else
  echo "⚠️ MariaDB StatefulSet may have imagePullSecrets issues (this should have been configured during Helm deployment)"
fi

GALERA_DEPLOY_PHASE="complete"  # Cleanup trap will see exit 0 + complete phase → no-op
echo "$DB_NAME Database deployment is complete."
