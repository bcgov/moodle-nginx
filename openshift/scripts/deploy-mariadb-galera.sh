# Deploy MariaDB Galera to OpenShift

echo "Deploying MariaDB Galera to: $DB_DEPLOYMENT_NAME..."

# Check if the Helm deployment exists
if helm list -q | grep -q "^$DB_DEPLOYMENT_NAME$"; then
  echo "$DB_DEPLOYMENT_NAME Installation found...Scaling to 0..."
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
  helm uninstall $DB_DEPLOYMENT_NAME
  echo "Recreating $DB_DEPLOYMENT_NAME..."
else
  echo "Helm deployment $DB_HOST NOT FOUND. Beginning deployment..."
fi

helm install $DB_HOST \
    --set db.user=$DB_USER \
    --set db.password=$DB_PASSWORD \
    --set db.name=$DB_NAME \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=256Mi \
    --set resources.limit.cpu=400m \
    --set resources.requests.memory=1024Mi \
    oci://registry-1.docker.io/bitnamicharts/mariadb-galera --atomic --wait --timeout 30 -f config.yaml
