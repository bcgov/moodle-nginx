echo "Deploy Memcached ..."

instance_name="memcached"
instance_chart="oci://registry-1.docker.io/bitnamicharts/memcached"

if helm list -q | grep -q "^$instance_name$"; then
  echo "Helm deployment found. Updating..."
  helm_upgrade_response=$(helm upgrade --reuse-values $instance_name $instance_chart)

  # Check the Helm deployment for errors
  if [[ $helm_upgrade_response =~ "Error" ]]; then
    echo "❌ Helm upgrade FAILED."
    echo "3. $helm_upgrade_response"
    exit 1
  fi
else
  echo "Helm deployment not found. Installing..."
  helm install $instance_name $instance_chart \
    --set architecture="high-availability" \
    --set autoscaling.minReplicas=3 \
    --set autoscaling.maxReplicas=20 \
    --set autoscaling.enabled=true \
    --set resources.requests.cpu=50m \
    --set resources.requests.memory=64Mi \
    --set resources.limits.cpu=100m \
    --set resources.limits.memory=256Mi \
    --set persistence.enabled=true \
    --set persistence.size=200Mi
fi

if [[ `oc describe sts/$instance_name 2>&1` =~ "NotFound" ]]; then
  echo "Helm chart ($instance_name) exists, but StatefulSet was NOT FOUND."
  exit 1
fi
