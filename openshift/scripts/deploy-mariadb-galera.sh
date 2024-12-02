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

  helm upgrade $DB_DEPLOYMENT_NAME \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
    --set rootUser.password=$DB_PASSWORD \
    --set db.user=$DB_USER \
    --set db.password=$DB_PASSWORD \
    --set db.name=$DB_NAME \
    --set galera.mariabackup.password=$DB_PASSWORD \
    --set galera.mariabackup.forcePassword=true

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
    --atomic \
    --wait \
    -f ./config/mariadb/galera-values.yaml
fi
