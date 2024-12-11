# Deploy MariaDB Galera to OpenShift

echo "Deploying MariaDB Galera to: $DB_DEPLOYMENT_NAME..."

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
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera --reuse-values \
    --set rootUser.password=$DB_PASSWORD \
    --set galera.mariabackup.password=$DB_PASSWORD \
    --set extraVolumeMounts[0].name=prestop-script \
    --set extraVolumeMounts[0].mountPath=/usr/local/bin/prestop.sh \
    --set extraVolumeMounts[0].subPath=mariadb-prestop.sh \
    --set extraVolumeMounts[0].readOnly=true \
    --set lifecycle.preStop.exec.command[0]="/bin/sh" \
    --set lifecycle.preStop.exec.command[1]="-c" \
    --set lifecycle.preStop.exec.command[2]="/usr/local/bin/prestop.sh" \
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
    --set replicaCount=4 \
    --set persistence.size=12Gi \
    --set primary.persistence.accessModes={ReadWriteMany} \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=256Mi \
    --set resources.limits.cpu=400m \
    --set resources.limits.memory=1024Mi \
    --set metrics.enabled=true \
    --set metrics.serviceMonitor.enabled=true \
    --set metrics.prometheusRules.enabled=true \
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
    -f ./config/mariadb/galera-values.yaml
fi

# Handle graceful shutdown, and introduce some testing parameters
oc create configmap $DB_DEPLOYMENT_NAME-prestop-script --from-file=./openshift/scripts/mariadb-prestop.sh

# Add the ConfigMap as a volume and mount it to each container.
# Also, add the preStop hook to use the script
# oc patch statefulset $DB_DEPLOYMENT_NAME --type=json -p '[{"op": "add", "path": "/spec/template/spec/volumes", "value": [{"name": "prestop-script", "configMap": {"name": "$DB_DEPLOYMENT_NAME-prestop-script"}}]}, {"op": "add", "path": "/spec/template/spec/containers/0/volumeMounts", "value": [{"name": "prestop-script", "mountPath": "/usr/local/bin/prestop.sh", "subPath": "mariadb-prestop.sh"}]}, {"op": "add", "path": "/spec/template/spec/containers/0/lifecycle", "value": {"preStop": {"exec": {"command": ["/bin/sh", "-c", "/usr/local/bin/prestop.sh"]}}}}]'

# Patch the StatefulSet to add the preStop hook to every container
oc patch statefulset $DB_DEPLOYMENT_NAME --type=json -p '[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "prestop-script",
      "configMap": {
        "name": "'"$DB_DEPLOYMENT_NAME"'-prestop-script"
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "prestop-script",
      "mountPath": "/usr/local/bin/prestop.sh",
      "subPath": "mariadb-prestop.sh"
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/lifecycle/preStop",
    "value": {
      "exec": {
        "command": ["/bin/sh", "-c", "/usr/local/bin/prestop.sh"]
      }
    }
  }
]'
