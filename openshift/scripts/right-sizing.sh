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

# Track failures across the pipe subshell
rm -f /tmp/right-sizing-failures.txt

# Read the CSV file line by line to set deployment resources
# based on those values
tail -n +2 ./openshift/${DEPLOY_NAMESPACE}-sizing.csv | while IFS=, read -r Deployment Type PodCount MaxPods PVCCount PVCCapacity CPURequest CPULimit MemRequest MemLimit CPUScaleValue
do
  echo "Right-sizing: $Type/$Deployment"

  # Ignore if the type is not statefulset or deployment (mainly ignores jobs)
  if [[ "$Type" == "sts" || "$Type" == "deployment" ]]; then
    set_resources "$Type" "$Deployment" "$CPURequest" "$MemRequest" "$CPULimit" "$MemLimit"
  fi

  if [[ $PodCount -eq 0 ]]; then
    echo "Skipping optional / temporary resource... no pods required to be running."
  else
    # Galera StatefulSets require incremental scaling (1→2→...→N) because
    # podManagementPolicy=Parallel (immutable) starts ALL pods at once.
    # Fresh secondary pods bootstrap independent clusters, which causes
    # split-brain or "conflicting prims" crashes.
    if [[ "$Type" == "sts" && "$Deployment" == *"galera"* && $PodCount -gt 1 ]]; then
      echo "📈 Incremental Galera scaling for $Deployment to $PodCount replicas..."
      GALERA_SCALE_FAILED=false
      for SCALE_TARGET in $(seq 1 $PodCount); do
        CURRENT=$(oc get sts/$Deployment -o jsonpath='{.spec.replicas}' -n "$DEPLOY_NAMESPACE" 2>/dev/null || echo "0")
        if [[ "$CURRENT" -ge "$SCALE_TARGET" ]]; then
          echo "   ✅ Already at $CURRENT replicas (target: $SCALE_TARGET)"
          continue
        fi
        echo "   📈 Scaling $Deployment to $SCALE_TARGET/$PodCount..."
        oc scale sts/$Deployment --replicas=$SCALE_TARGET -n "$DEPLOY_NAMESPACE"
        NEW_POD="${Deployment}-$((SCALE_TARGET - 1))"
        echo "   ⏳ Waiting for $NEW_POD to be Ready..."
        READY_ATTEMPTS=0
        MAX_READY_ATTEMPTS=60
        while [[ $READY_ATTEMPTS -lt $MAX_READY_ATTEMPTS ]]; do
          POD_READY=$(oc get pod "$NEW_POD" -n "$DEPLOY_NAMESPACE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
          if [[ "$POD_READY" == "True" ]]; then
            echo "   ✅ $NEW_POD is Ready"
            break
          fi
          sleep 10
          READY_ATTEMPTS=$((READY_ATTEMPTS + 1))
          if [[ $((READY_ATTEMPTS % 6)) -eq 0 ]]; then
            echo "   ⏳ Still waiting for $NEW_POD... $((READY_ATTEMPTS * 10))s elapsed"
          fi
        done
        if [[ $READY_ATTEMPTS -eq $MAX_READY_ATTEMPTS ]]; then
          echo "   ❌ $NEW_POD failed to become Ready within 600s"
          GALERA_SCALE_FAILED=true
          break
        fi
      done
      if [[ "$GALERA_SCALE_FAILED" == "true" ]]; then
        echo "❌ $Type/$Deployment incremental scaling failed"
        echo "FAILED:$Type/$Deployment (incremental scaling)" >> /tmp/right-sizing-failures.txt
      fi
    else
      if ! scale_deployment "$Type" "$Deployment" "$PodCount" "$MaxPods"; then
        echo "❌ $Type/$Deployment failed to stabilize after scaling"
        # Signal failure to parent shell via temp file (pipe subshell can't set vars)
        echo "FAILED:$Type/$Deployment" >> /tmp/right-sizing-failures.txt
      fi
    fi

    # Galera-specific: verify cluster synchronization and consistency after scaling.
    # scale_deployment only checks pod logs — it doesn't verify Galera state.
    # Pods can appear "healthy" while in split-brain (independent clusters).
    if [[ "$Type" == "sts" && "$Deployment" == *"galera"* ]]; then
      echo "🔍 Verifying Galera cluster synchronization for $Deployment..."
      if ! wait_for_galera_sync "$Deployment" 30 10 "$PodCount"; then
        echo "❌ $Deployment Galera cluster failed to synchronize after right-sizing"
        echo "FAILED:$Type/$Deployment (Galera sync)" >> /tmp/right-sizing-failures.txt
      else
        echo "✅ $Deployment Galera cluster is synchronized ($PodCount nodes)"
        # Additional split-brain check — verify all pods share the same cluster UUID
        check_galera_cluster_health "app.kubernetes.io/name=$Deployment" "$DEPLOY_NAMESPACE" "$PodCount"
        GALERA_HEALTH=$?
        if [[ $GALERA_HEALTH -eq 2 ]]; then
          echo "🚨 SPLIT-BRAIN DETECTED in $Deployment after right-sizing!"
          echo "FAILED:$Type/$Deployment (split-brain)" >> /tmp/right-sizing-failures.txt
        elif [[ $GALERA_HEALTH -eq 1 ]]; then
          echo "⚠️ $Deployment has unhealthy pods after right-sizing"
          echo "FAILED:$Type/$Deployment (unhealthy pods)" >> /tmp/right-sizing-failures.txt
        fi
      fi
    fi

    # Check if MaxPods is greater than PodCount before creating the HPA
    if [[ $MaxPods -gt $PodCount ]]; then
      create_hpa "$Deployment" "$Type/$Deployment" "$PodCount" "$MaxPods" "$CPUScaleValue"
    else
      echo "Skipping HPA creation for $Type/$Deployment: MaxPods ($MaxPods) is not greater than PodCount ($PodCount)."
    fi
  fi
done

# Check for any failures that occurred in the pipe subshell
if [[ -f /tmp/right-sizing-failures.txt ]]; then
  echo ""
  echo "❌ RIGHT-SIZING FAILURES DETECTED:"
  cat /tmp/right-sizing-failures.txt
  echo ""
  echo "⚠️  Some resources failed to stabilize after scaling."
  echo "   The site should NOT exit maintenance mode until these are resolved."
  rm -f /tmp/right-sizing-failures.txt
  exit 1
fi

rm -f /tmp/right-sizing-failures.txt
echo "✅ Right-sizing completed successfully."
