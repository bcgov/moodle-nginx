if [[ `oc describe deployment $BUILD_NAME 2>&1` =~ "NotFound" ]]; then
  echo "$BUILD_NAME NOT FOUND: Beginning deployment..."
  oc process -f ./openshift/maintenance.yml \
    -p IMAGE_REPO=$IMAGE_REPO \
    -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
    -p BUILD_NAME=$BUILD_NAME \
    | oc create -f -
else
  echo "$BUILD_NAME Installation found...Scaling to 0..."
  oc scale deployment $BUILD_NAME --replicas=0

  ATTEMPTS=0
  MAX_ATTEMPTS=60
  while [[ $(oc get deployment $BUILD_NAME -o jsonpath='{.status.replicas}') -ne 0 && $ATTEMPTS -ne $MAX_ATTEMPTS ]]; do
    echo "Waiting for $BUILD_NAME to scale to 0..."
    sleep 10
    ATTEMPTS=$((ATTEMPTS + 1))
  done
  if [[ $ATTEMPTS -eq $MAX_ATTEMPTS ]]; then
    echo "Timeout waiting for $BUILD_NAME to scale to 0"
    exit 1
  fi

  echo "Recreating $BUILD_NAME..."
  oc delete deployment $BUILD_NAME -n $DEPLOY_NAMESPACE
  oc delete configmap maintenance-page -n $DEPLOY_NAMESPACE

  oc process -f ./openshift/maintenance.yml \
    -p IMAGE_REPO=$IMAGE_REPO \
    -p DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
    -p BUILD_NAME=$BUILD_NAME \
    | oc create -f -
fi

# Wait for the deployment to scale to 1
ATTEMPTS=0
MAX_ATTEMPTS=60
while [[ $(oc get deployment $BUILD_NAME -o jsonpath='{.status.replicas}') -ne 1 && $ATTEMPTS -ne $MAX_ATTEMPTS ]]; do
  echo "Waiting for $BUILD_NAME to scale to 1..."
  sleep 10
  ATTEMPTS=$((ATTEMPTS + 1))
done
if [[ $ATTEMPTS -eq $MAX_ATTEMPTS ]]; then
  echo "Timeout waiting for $BUILD_NAME to scale to 1"
  exit 1
fi

echo "$BUILD_NAME deployment complete"

# Redirect traffic to $BUILD_NAME
echo "Redirecting traffic to $BUILD_NAME..."
oc patch route moodle-web --type=json -p '[{"op": "replace", "path": "/spec/to/name", "value": "$BUILD_NAME"}]'
