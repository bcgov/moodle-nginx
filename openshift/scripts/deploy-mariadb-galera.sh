# Deploy MariaDB Galera to OpenShift

echo "Deploying MariaDB Galera to: $DB_DEPLOYMENT_NAME..."

PATCH_FILE="config/mariadb/mariadb-galera-prestop-patch.json"

# Check if the Helm deployment exists
if helm list -q | grep -q "^$DB_DEPLOYMENT_NAME$"; then
  echo "$DB_DEPLOYMENT_NAME Installation found...Skipping..."
  oc scale sts/$DB_DEPLOYMENT_NAME --replicas=0
  ATTEMPTS=0
  MAX_ATTEMPTS=60
  while [[ $(oc get sts/$DB_DEPLOYMENT_NAME -o jsonpath='{.status.replicas}') -ne 0 && $ATTEMPTS -ne $MAX_ATTEMPTS ]]; do
    echo "Waiting for $DB_DEPLOYMENT_NAME to scale to 0..."
    sleep 10
    ATTEMPTS=$((ATTEMPTS + 1))
  done
  if [[ $ATTEMPTS -eq $MAX_ATTEMPTS ]]; then
    echo "Timeout waiting for $DB_DEPLOYMENT_NAME to scale to 0"
    exit 1
  fi

  # helm uninstall $DB_DEPLOYMENT_NAME
  echo "Upgrading $DB_DEPLOYMENT_NAME..."

  # Capture the output of the helm upgrade command into a variable
  helm_upgrade_response=$(helm upgrade $DB_DEPLOYMENT_NAME \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
    --reuse-values \
    --set rootUser.password=$DB_PASSWORD \
    --set galera.mariabackup.password=$DB_PASSWORD \
    -f ./config/mariadb/galera-values.yaml 2>&1)

   # Output the response for debugging purposes
  echo "$helm_upgrade_response"

  # Check if the helm upgrade command failed
  if [[ $? -ne 0 ]]; then
    echo "Helm upgrade failed with the following output:"
    echo "$helm_upgrade_response"
    exit 1
  fi

  # helm upgrade $DB_DEPLOYMENT_NAME \
  #   oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  #   --set rootUser.password=$DB_PASSWORD \
  #   --set galera.mariabackup.password=$DB_PASSWORD
  #   -f ./config/mariadb/galera-values.yaml
    # --set db.password=$DB_PASSWORD \
    # --set db.user=$DB_USER \
    # --set db.name=$DB_NAME \
    # --set galera.mariabackup.forcePassword=true

else
  echo "Helm deployment $DB_DEPLOYMENT_NAME NOT FOUND. Beginning deployment..."

  helm install $DB_DEPLOYMENT_NAME \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
    --set image.debug=true \
    --set image.tag=10.4 \
    --set rootUser.password=$DB_PASSWORD \
    --set db.user=$DB_USER \
    --set db.password=$DB_PASSWORD \
    --set db.name=$DB_NAME \
    --set replicaCount=3 \
    --set persistence.size=12Gi \
    --set primary.persistence.accessModes={ReadWriteMany} \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=256Mi \
    --set resources.limits.cpu=400m \
    --set resources.limits.memory=1024Mi \
    --set metrics.enabled=true \
    --set metrics.serviceMonitor.enabled=true \
    --set metrics.prometheusRules.enabled=false \
    --set readinessProbe.enabled=false \
    --set livenessProbe.enabled=false \
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
    --set lifecycle.preStop.exec.command[2]="/usr/local/bin/prestop.sh" \
    --atomic \
    --wait \
    --timeout 20m \
    -f ./config/mariadb/galera-values.yaml
fi

# Create or update the ConfigMap from the prestop.sh script
if oc get configmap ${DB_DEPLOYMENT_NAME}-prestop-script &> /dev/null; then
  echo "ConfigMap ${DB_DEPLOYMENT_NAME}-prestop-script already exists. Updating..."
  oc create configmap ${DB_DEPLOYMENT_NAME}-prestop-script --from-file=./openshift/scripts/mariadb-prestop.sh -o yaml --dry-run=client | oc apply -f -
else
  echo "Creating ConfigMap ${DB_DEPLOYMENT_NAME}-prestop-script..."
  oc create configmap ${DB_DEPLOYMENT_NAME}-prestop-script --from-file=./openshift/scripts/mariadb-prestop.sh
fi

# Function to check if a JSON path exists in the StatefulSet
json_path_exists() {
  local path=$1
  oc get statefulset $DB_DEPLOYMENT_NAME -o jsonpath="$path" &> /dev/null
}

# Define the patches to add preStop hook to the StatefulSet
patches=(
  '{"op": "add", "path": "/spec/template/spec/volumes/-", "value": {"name": "prestop-script", "configMap": {"name": "mariadb-galera-prestop-script"}}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts/-", "value": {"name": "prestop-script", "mountPath": "/usr/local/bin/prestop.sh", "subPath": "mariadb-prestop.sh", "readOnly": true}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/lifecycle", "value": {}}'
  '{"op": "add", "path": "/spec/template/spec/containers/0/lifecycle/preStop", "value": {"exec": {"command": ["/bin/sh", "-c", "/usr/local/bin/prestop.sh"]}}}'
)

# Define the JSON paths to check if the patches have been applied
paths=(
  '{.spec.template.spec.volumes[?(@.name=="prestop-script")]}'
  '{.spec.template.spec.containers[0].volumeMounts[?(@.name=="prestop-script")]}'
  '{.spec.template.spec.containers[0].lifecycle}'
  '{.spec.template.spec.containers[0].lifecycle.preStop}'
)

# Patch the StatefulSet to add the preStop hook to every container
if oc get statefulset $DB_DEPLOYMENT_NAME &> /dev/null; then
  echo "Applying JSON patch from $PATCH_FILE"
  cat $PATCH_FILE

  # Collect patches to apply
  patches_to_apply=()
  for i in "${!paths[@]}"; do
    if ! json_path_exists "${paths[$i]}"; then
      patches_to_apply+=("${patches[$i]}")
    fi
  done

  # Apply patches if there are any to apply
  if [ ${#patches_to_apply[@]} -gt 0 ]; then
    oc patch statefulset $DB_DEPLOYMENT_NAME --type=json -p "[${patches_to_apply[*]}]"
  else
    echo "All patches already applied. No changes needed."
  fi
else
  echo "StatefulSet $DB_DEPLOYMENT_NAME not found. Skipping patch."
fi

sleep 10

oc scale sts/$DB_DEPLOYMENT_NAME --replicas=1

sleep 15

# Wait for the deployment to scale to 1
ATTEMPTS=0
MAX_ATTEMPTS=60
while [[ $(oc get sts $DB_DEPLOYMENT_NAME -o jsonpath='{.status.replicas}') -ne 1 && $ATTEMPTS -ne $MAX_ATTEMPTS ]]; do
  echo "Waiting for $DB_DEPLOYMENT_NAME to scale to 1..."
  sleep 10
  ATTEMPTS=$((ATTEMPTS + 1))
done
if [[ $ATTEMPTS -eq $MAX_ATTEMPTS ]]; then
  echo "Timeout waiting for $DB_DEPLOYMENT_NAME to scale to 1"
  exit 1
fi

echo "Checking if the database is online and contains expected Moodle data..."
ATTEMPTS=0
WAIT_TIME=10
MAX_ATTEMPTS=30 # wait up to 5 minutes

# Get the name of the first pod in the StatefulSet
DB_POD_NAME=""
until [ -n "$DB_POD_NAME" ]; do
  ATTEMPTS=$(( $ATTEMPTS + 1 ))
  DB_POD_NAME=$(oc get pods -l app=$DB_DEPLOYMENT_NAME -o jsonpath='{.items[?(@.status.phase=="Running")].metadata.name}')

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

until [ $ATTEMPTS -eq $MAX_ATTEMPTS ]; do
  ATTEMPTS=$(( $ATTEMPTS + 1 ))
  echo "Waiting for database to come online... $(($ATTEMPTS * $WAIT_TIME)) seconds..."

  # Capture the output of the mariadb command
  OUTPUT=$(oc exec $DB_POD_NAME -- bash -c "mariadb -u root -e 'USE $DB_NAME; SELECT COUNT(*) FROM user;'" 2>&1)

  # Check if the output contains an error
  if echo "$OUTPUT" | grep -qi "error"; then
    echo "❌ Database error: $OUTPUT"
    # exit 1
  fi

  # Extract the user count from the output
  CURRENT_USER_COUNT=$(echo "$OUTPUT" | grep -oP '\d+')

  if [ $CURRENT_USER_COUNT -gt 0 ]; then
    echo "Database is online and contains $CURRENT_USER_COUNT users."
    echo "Resetting master to avoid repolication issues..."
    RESET=$(oc exec $DB_POD_NAME -- bash -c "mariadb -u root -e 'RESET MASTER;'" 2>&1)
    echo "Result: $RESET"
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

echo "$DB_NAME Database deployment is complete."
