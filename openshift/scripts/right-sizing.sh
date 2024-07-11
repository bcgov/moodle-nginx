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

      # First, remove the existing autoscaler if it exists
      cmd="oc get hpa $Deployment"
      if $cmd &> /dev/null; then
          echo "Removing existing HorizontalPodAutoscaler for $Deployment"
          oc delete hpa/$Deployment
      fi

      # Calculate the difference
      diff=$((MaxPods - PodCount))
      if [[ $diff -gt 0 ]]; then
        # If MaxPods > PodCount, add HorizontalPodAutoscaler
        cmd="oc autoscale dc/$Deployment --min $PodCount --max $MaxPods --cpu-percent=80"
        echo "Executing: $cmd"
        $cmd
      fi
      # Calculate the percentage
      maxSurge=$(( (diff * 100) / PodCount ))
      # Append the percentage sign
      maxSurge="${maxSurge}%"
      # Patch the deployment
      echo "Executing: oc patch dc $Deployment -p={\"spec\":{\"strategy\":{\"rollingParams\":{\"maxSurge\":\"$maxSurge\", \"maxUnavailable\":\"66%\"}}}}"
      oc patch dc $Deployment -p="{\"spec\":{\"strategy\":{\"rollingParams\":{\"maxSurge\":\"$maxSurge\", \"maxUnavailable\":\"66%\"}}}}"
  fi
done

sleep 60

# Add service for each redis pod
echo "Deploy Redis Service for each pod ..."
# Collect all pods related to the Redis StatefulSet
PODS=$(oc get pods -l app=$REDIS_DEPLOYMENT_NAME -n $DEPLOY_NAMESPACE -o jsonpath='{.items[*].metadata.name}')

# Loop through each pod
for POD_NAME in $PODS; do
  # Create a service for each pod using the redis-services template
  sed "s/\${POD_NAME}/$POD_NAME/g" < ./openshift/redis-services.yml | oc apply -f -
  echo "Service created for pod $POD_NAME"
done
