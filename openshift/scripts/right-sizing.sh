echo "Right-sizing cluster..."
#!/bin/bash
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
tail -n +2 ./openshift/${DEPLOY_NAMESPACE}-sizing.csv | while IFS=, read -r Deployment Type PodCount MaxPods PVCCount PVCCapacity CPURequest CPULimit MemRequest MemLimit
do
  # Ignore if the type is 'job'
  if [[ "$Type" == "sts" || "$Type" == "dc" ]]
  then
      # Build the command
      cmd="oc set resources $Type $Deployment --limits=cpu=${CPULimit}m,memory=${MemLimit}Mi --requests=cpu=${CPURequest}m,memory=${MemRequest}Mi"

      # Execute the command
      echo "Executing: $cmd"
      $cmd
  fi

  if [[ "$Type" == "sts" ]]
  then
      # For StatefulSet, scale to the desired number of pods
      cmd="oc scale sts $Deployment --replicas=$PodCount"
      echo "Executing: $cmd"
      $cmd
  elif [[ "$Type" == "dc" ]]
  then
      # For DeploymentConfig, set the number of current pods and maximum replicas
      cmd="oc scale dc $Deployment --replicas=$PodCount"
      echo "Executing: $cmd"
      $cmd
      cmd="oc patch dc $Deployment -p='{\"spec\":{\"strategy\":{\"rollingParams\":{\"maxSurge\":$MaxPods}}}}'"
      echo "Executing: $cmd"
      $cmd
  fi
done
