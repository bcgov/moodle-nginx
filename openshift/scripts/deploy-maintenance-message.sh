#!/bin/bash
#==============================================================================
# deploy-maintenance-message.sh
#==============================================================================
# PURPOSE:
#   Deploy standalone maintenance message page during extended outages or
#   major upgrades. Replaces main application with lightweight NGINX serving
#   static HTML maintenance page.
#
# USE CASES:
#   - Extended maintenance windows (> 30 minutes)
#   - Major version upgrades requiring extensive downtime
#   - Infrastructure changes affecting multiple services
#   - Planned outages requiring user notification
#
# ARCHITECTURE:
#   - Deploys dedicated NGINX deployment (maintenance-message)
#   - Serves static HTML from ConfigMap (maintenance-page)
#   - Uses minimal resources (no PHP, no database)
#   - Routes traffic via existing moodle-web route
#
# DEPLOYMENT FLOW:
#   1. Create ConfigMaps (maintenance-page, maintenance-config)
#   2. Scale down existing deployment if present
#   3. Delete old deployment and service
#   4. Deploy maintenance.yml template
#   5. Wait for rollout completion
#
# CONFIGURATION:
#   BUILD_NAME               - Deployment name (default: maintenance-message)
#   DEPLOY_NAMESPACE         - Target namespace
#   WEB_IMAGE                - NGINX image to use
#   ARTIFACTORY_PULL_SECRET  - Image pull secret
#
# USAGE:
#   # Deploy maintenance page
#   export BUILD_NAME="maintenance-message"
#   export WEB_IMAGE="nginx:alpine"
#   ./openshift/scripts/deploy-maintenance-message.sh
#
#   # Remove maintenance page (restore application)
#   oc delete deployment/maintenance-message
#   oc delete svc/maintenance-message
#   # Then deploy main application
#
# RELATED DOCS:
#   - Template: ../maintenance.yml
#   - HTML: ../../config/maintenance/index.html
#   - NGINX Config: ../../config/nginx/maintenance.conf
#==============================================================================

DEPLOYMENT_SELECTOR="deployment/$BUILD_NAME"
ROUTE_NAME="moodle-web"

# Source the utility script
source ./openshift/scripts/_utils.sh

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

# Check if the utility script is sourced correctly
if ! type deploy_resource_from_template &> /dev/null; then
  echo "Error: deploy_resource_from_template function not found. Ensure _utils.sh is sourced correctly."
  exit 1
fi

if ! type wait_for &> /dev/null; then
  echo "Error: wait_for function not found. Ensure _utils.sh is sourced correctly."
  exit 1
fi

# maintenance html page
create_or_update_configmap maintenance-page ./config/maintenance/index.html

# maintenance nginx config
create_or_update_configmap maintenance-config default.conf=./config/nginx/maintenance.conf

if [[ `oc describe $DEPLOYMENT_SELECTOR 2>&1` =~ "NotFound" ]]; then
  echo "$DEPLOYMENT_SELECTOR NOT FOUND: Beginning deployment..."
else
  echo "$DEPLOYMENT_SELECTOR Installation found...Scaling to 0..."
  oc scale $DEPLOYMENT_SELECTOR --replicas=0
  wait_for "$DEPLOYMENT_SELECTOR" "ready" "200s" "down"

  echo "Recreating $BUILD_NAME..."
  oc delete $DEPLOYMENT_SELECTOR -n $DEPLOY_NAMESPACE
  oc delete svc/$BUILD_NAME -n $DEPLOY_NAMESPACE

  sleep 5
fi

deploy_resource_from_template ./openshift/maintenance.yml \
  DEPLOY_NAMESPACE=$DEPLOY_NAMESPACE \
  WEB_IMAGE=$WEB_IMAGE \
  BUILD_NAME=$BUILD_NAME \
  ARTIFACTORY_PULL_SECRET=$ARTIFACTORY_PULL_SECRET

# Wait for the deployment/to scale to 1
if ! wait_for "$DEPLOYMENT_SELECTOR" "ready" "1500s"; then
  # If maintenance deployment failed
  # exit the deployment before changing the route
  echo "$DEPLOYMENT_SELECTOR failed. Exiting..."
  exit 1
fi

# Redirect traffic to maintenance-message using environment-aware routing
echo "Redirecting all routes to maintenance-message..."
patch_all_routes "$BUILD_NAME"
