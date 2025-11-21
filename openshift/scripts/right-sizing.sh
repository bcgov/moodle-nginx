#!/bin/bash
#==============================================================================
# right-sizing.sh
#==============================================================================
# PURPOSE:
#   Apply resource allocation (CPU/memory requests and limits) and scaling
#   configuration (pod count, HPA settings) to all deployments and StatefulSets
#   in the namespace based on CSV configuration files.
#
# CSV FORMAT:
#   Deployment,Type,PodCount,MaxPods,PVCCount,PVCCapacity,CPURequest,CPULimit,MemRequest,MemLimit,CPUScaleValue
#   moodle-php,deployment,3,10,0,0,500m,2000m,1Gi,4Gi,80
#   mariadb-galera,sts,3,3,3,20Gi,1000m,4000m,4Gi,8Gi,80
#
# ARCHITECTURE:
#   Reads CSV file: ./openshift/${DEPLOY_NAMESPACE}-sizing.csv
#   - Sets resource requests/limits for each deployment
#   - Scales pods to specified count
#   - Creates HorizontalPodAutoscaler if MaxPods > PodCount
#   - Skips resources with PodCount=0 (optional/temporary resources)
#
# QUICK CONFIG:
#   DEPLOY_NAMESPACE         - Determines CSV file to use (required)
#   CSV Location             - ./openshift/${DEPLOY_NAMESPACE}-sizing.csv
#
# USAGE:
#   # Apply sizing for dev namespace
#   export DEPLOY_NAMESPACE="e66ac2-dev"
#   ./openshift/scripts/right-sizing.sh
#
#   # Apply sizing for prod namespace
#   export DEPLOY_NAMESPACE="950003-prod"
#   ./openshift/scripts/right-sizing.sh
#
# CSV FILES:
#   - Dev:  ./openshift/e66ac2-dev-sizing.csv
#   - Test: ./openshift/950003-test-sizing.csv
#   - Prod: ./openshift/950003-prod-sizing.csv
#
# RELATED DOCS:
#   - SharePoint source (manual export):
#     "OpenShift Cluster Right-Sizing" spreadsheet
#   - Future: Direct Microsoft Graph API integration
#==============================================================================

echo "Right-sizing cluster..."

# Source the utility script
source ./openshift/scripts/_utils.sh

# Initialize utility file arrays for any containerized operations
initialize_utility_arrays

# Read the CSV file line by line to set deployment resources
# based on those values
tail -n +2 ./openshift/${DEPLOY_NAMESPACE}-sizing.csv | while IFS=, read -r Deployment Type PodCount MaxPods PVCCount PVCCapacity CPURequest CPULimit MemRequest MemLimit CPUScaleValue
do
  echo "Right-sizing: $Type/$Deployment"

  # Ignore if the type is not statefulset or deployemnt (mainly ignores jobs)
  if [[ "$Type" == "sts" || "$Type" == "deployment" ]]; then
    set_resources "$Type" "$Deployment" "$CPURequest" "$MemRequest"
  fi

  if [[ $PodCount -eq 0 ]]; then
    echo "Skipping optional / temporary resource... no pods required to be running."
  else
    scale_deployment "$Type" "$Deployment" "$PodCount" "$MaxPods"

    # Check if MaxPods is greater than PodCount before creating the HPA
    if [[ $MaxPods -gt $PodCount ]]; then
      create_hpa "$Deployment" "$Type/$Deployment" "$PodCount" "$MaxPods" "$CPUScaleValue"
    else
      echo "Skipping HPA creation for $Type/$Deployment: MaxPods ($MaxPods) is not greater than PodCount ($PodCount)."
    fi
  fi
done
