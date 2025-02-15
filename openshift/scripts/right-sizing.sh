#!/bin/bash
#set -e # Exit on error

echo "Right-sizing cluster..."

# Read the CSV file line by line and set deployment resources
# The file is chosen using the DEPLOY_NAMESPACE environment variable (+ '-sizing.csv')
# Ensure that there is a CSV file for each namespace
# This is to allow the correct resources to be set for each deployment
# Example: ./openshift/e66ac2-dev-sizing.csv
## Hope to replace this with a direct call to the Microsoft Graph API in the future
## If we can get permissions sorted out for a service account
# For now, the CSV file is generated manually by exporting the "Export" tabs from the
# "OpenShift Cluster Right-Sizing" sheet:
# https://bcgov-my.sharepoint.com/:x:/r/personal/warren_christian_gov_bc_ca/_layouts/15/Doc.aspx?sourcedoc=%7BC236A074-8A5C-4B2F-AE7C-9F2F393AF8CE%7D&file=OpenShift%20Cluster%20Right-Sizing.xlsx&action=default&mobileredirect=true
# You can always just edit/copy the CSV files and adjust manually
# Read the CSV file line by line and set deployment resources

# Source the utility script
source ./openshift/scripts/_utils.sh

# Read the CSV file line by line to set deployment resources
# based on those values
tail -n +2 ./openshift/${DEPLOY_NAMESPACE}-sizing.csv | while IFS=, read -r Deployment Type PodCount MaxPods PVCCount PVCCapacity CPURequest CPULimit MemRequest MemLimit CPUScaleValue
do
  echo "$Deployment ($Type)"
  # Ignore if the type is 'job'
  if [[ "$Type" == "sts" || "$Type" == "deployment" ]]; then
    set_resources "$Type" "$Deployment" "$CPURequest" "$CPULimit" "$MemRequest" "$MemLimit"
  fi

  if [[ $PodCount -eq 0 ]]; then
    echo "Skipping optional / temporary resource... no pods required to be running."
  else
    scale_deployment "$Type" "$Deployment" "$PodCount" "$MaxPods"

    # Create new HPAs for the deployment
    create_hpa "$Deployment" "$Type/$Deployment" "$PodCount" "$MaxPods" "$CPUScaleValue"
  fi
done
