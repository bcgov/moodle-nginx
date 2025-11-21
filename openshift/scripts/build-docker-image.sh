#!/bin/bash
#==============================================================================
# build-docker-image.sh
#==============================================================================
# PURPOSE:
#   Triggers OpenShift BuildConfig to build container images from source code.
#   Processes docker-build.yml template with parameters and starts the build.
#
# ARCHITECTURE:
#   1. Process OpenShift template (docker-build.yml)
#   2. Apply BuildConfig to cluster
#   3. Start build with specific commit/branch
#   4. Wait for build completion (--wait flag)
#
# CONFIGURATION:
#   BRANCH                   - Git branch/commit to build (required)
#   BUILD_NAMESPACE          - OpenShift namespace for builds (required)
#   DEPLOYMENT_NAME          - Name of the deployment/image (required)
#   DOCKER_FROM_IMAGE        - Base image for Dockerfile
#   DOCKER_FILE_PATH         - Path to Dockerfile
#   SOURCE_REPOSITORY_URL    - Git repository URL
#   SOURCE_CONTEXT_DIR       - Build context directory
#
# MOODLE VERSIONS:
#   MOODLE_BRANCH_VERSION    - Core Moodle version
#   HVP_BRANCH_VERSION       - H5P plugin version
#   PSAELMSYNC_BRANCH_VERSION - LMS sync plugin version
#   COURSESEARCH_BRANCH_VERSION - Course search plugin version
#   PCURATOR_BRANCH_VERSION  - Portfolio curator plugin version
#   REPORT_ALL_BACKUPS_BRANCH_VERSION - Backup report plugin version
#
# USAGE:
#   # Build from specific branch
#   export BRANCH="main"
#   export BUILD_NAMESPACE="e66ac2-tools"
#   export DEPLOYMENT_NAME="moodle-php"
#   ./openshift/scripts/build-docker-image.sh
#
# CI/CD INTEGRATION:
#   Called by: .github/workflows/build.yml (build job)
#
# RELATED DOCS:
#   - Template: ../docker-build.yml
#   - Dockerfiles: ../../Moodle.Dockerfile, ../../PHP.Dockerfile
#   - CI/CD: ../../.github/workflows/build.yml
#==============================================================================

test -n "$BRANCH"
test -n "$BUILD_NAMESPACE"
echo "BUILIDING $DEPLOYMENT_NAME:$BRANCH"
  oc -n $BUILD_NAMESPACE process -f ./openshift/docker-build.yml \
    -p NAME=$DEPLOYMENT_NAME \
    -p DOCKER_FROM_IMAGE=$DOCKER_FROM_IMAGE \
    -p IMAGE_REPO=$IMAGE_REPO \
    -p IMAGE_NAME=$DEPLOYMENT_NAME \
    -p IMAGE_TAG=$BUILD_NAMESPACE \
    -p SOURCE_REPOSITORY_URL=$SOURCE_REPOSITORY_URL \
    -p DOCKER_FILE_PATH=$DOCKER_FILE_PATH \
    -p DB_NAME: $DB_NAME \
    -p DB_USER: $DB_USER \
    -p DB_PASSWORD: $DB_PASSWORD \
    -p PHP_INI_ENVIRONMENT=$PHP_INI_ENVIRONMENT \
    -p MOODLE_BRANCH_VERSION=$MOODLE_BRANCH_VERSION \
    -p HVP_BRANCH_VERSION=$HVP_BRANCH_VERSION \
    -p PSAELMSYNC_BRANCH_VERSION=$PSAELMSYNC_BRANCH_VERSION \
    -p COURSESEARCH_BRANCH_VERSION=$COURSESEARCH_BRANCH_VERSION \
    -p PCURATOR_BRANCH_VERSION=$PCURATOR_BRANCH_VERSION \
    -p REPORT_ALL_BACKUPS_BRANCH_VERSION=$REPORT_ALL_BACKUPS_BRANCH_VERSION \
    -p BACKUP_IMAGE=$BACKUP_IMAGE \
    -p SOURCE_CONTEXT_DIR=$SOURCE_CONTEXT_DIR | oc -n $BUILD_NAMESPACE apply -f -
oc -n $BUILD_NAMESPACE start-build bc/$DEPLOYMENT_NAME --commit=$BRANCH --no-cache --wait
