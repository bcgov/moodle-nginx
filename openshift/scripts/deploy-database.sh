if [[ `oc describe sts $DB_DEPLOYMENT_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$DB_DEPLOYMENT_NAME NOT FOUND: Beginning deployment..."
  oc create -f ./config/mariadb/config.yaml -n $DEPLOY_NAMESPACE
else
  echo "$DB_DEPLOYMENT_NAME Installation found...Scaling to 0..."
  oc scale sts $DB_DEPLOYMENT_NAME --replicas=0

  ATTEMPTS=0
  MAX_ATTEMPTS=60
  while [[ $(oc get sts $DB_DEPLOYMENT_NAME -o jsonpath='{.status.replicas}') -ne 0 && $ATTEMPTS -ne $MAX_ATTEMPTS ]]; do
    echo "Waiting for $DB_DEPLOYMENT_NAME to scale to 0..."
    sleep 10
    ATTEMPTS=$((ATTEMPTS + 1))
  done
  if [[ $ATTEMPTS -eq $MAX_ATTEMPTS ]]; then
    echo "Timeout waiting for $DB_DEPLOYMENT_NAME to scale to 0"
    exit 1
  fi

  echo "Recreating $DB_DEPLOYMENT_NAME..."
  oc delete sts $DB_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE
  oc delete configmap $DB_DEPLOYMENT_NAME-config -n $DEPLOY_NAMESPACE
  oc delete service $DB_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE
  envsubst < ./config/mariadb/config.yaml | oc create -f - -n $DEPLOY_NAMESPACE
  # oc annotate --overwrite  sts/$DB_DEPLOYMENT_NAME kubectl.kubernetes.io/restartedAt=`date +%FT%T` -n $DEPLOY_NAMESPACE
  # oc rollout restart sts/$DB_DEPLOYMENT_NAME

  echo "Scaling $DB_DEPLOYMENT_NAME to 1..."
  oc scale sts $DB_DEPLOYMENT_NAME --replicas=1

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
fi
