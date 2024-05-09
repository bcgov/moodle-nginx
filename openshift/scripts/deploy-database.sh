if [[ `oc describe sts ${{ inputs.DB_DEPLOYMENT_NAME  }} 2>&1` =~ "NotFound" ]]; then
  echo "${{ inputs.DB_DEPLOYMENT_NAME  }} NOT FOUND: Beginning deployment..."
  oc create -f ./config/mariadb/config.yaml -n ${{ inputs.DEPLOY_NAMESPACE }}
else
  echo "${{ inputs.DB_DEPLOYMENT_NAME  }} Installation found...Scaling to 0..."
  oc scale sts ${{ inputs.DB_DEPLOYMENT_NAME  }} --replicas=0

  ATTEMPTS=0
  MAX_ATTEMPTS=60
  while [[ $(oc get sts ${{ inputs.DB_DEPLOYMENT_NAME }} -o jsonpath='{.status.replicas}') -ne 0 && $ATTEMPTS -ne $MAX_ATTEMPTS ]]; do
    echo "Waiting for ${{ inputs.DB_DEPLOYMENT_NAME }} to scale to 0..."
    sleep 10
    ATTEMPTS=$((ATTEMPTS + 1))
  done
  if [[ $ATTEMPTS -eq $MAX_ATTEMPTS ]]; then
    echo "Timeout waiting for ${{ inputs.DB_DEPLOYMENT_NAME }} to scale to 0"
    exit 1
  fi

  echo "Recreating ${{ inputs.DB_DEPLOYMENT_NAME  }}..."
  oc delete sts ${{ inputs.DB_DEPLOYMENT_NAME  }} -n ${{ inputs.DEPLOY_NAMESPACE }}
  oc delete configmap ${{ inputs.DB_DEPLOYMENT_NAME  }}-config -n ${{ inputs.DEPLOY_NAMESPACE }}
  oc delete service ${{ inputs.DB_DEPLOYMENT_NAME  }} -n ${{ inputs.DEPLOY_NAMESPACE }}
  oc create -f ./config/mariadb/config.yaml -n ${{ inputs.DEPLOY_NAMESPACE }}
  oc annotate --overwrite  sts/${{ inputs.DB_DEPLOYMENT_NAME  }} kubectl.kubernetes.io/restartedAt=`date +%FT%T` -n ${{ inputs.DEPLOY_NAMESPACE }}
  # oc rollout restart sts/${{ inputs.DB_DEPLOYMENT_NAME  }}
fi
