# =============================================================================
# EMERGENCY GALERA RECOVERY - MANUAL COMMANDS
# =============================================================================
# Use when: pod-health-monitor is unavailable or you need direct control
# Scenario: All Galera pods in CrashLoopBackOff with "safe_to_bootstrap: 0"
# =============================================================================

# Step 1: Check current state
oc get statefulset mariadb-galera -n 950003-prod
oc get pods -l app.kubernetes.io/name=mariadb-galera -n 950003-prod
oc get pvc -l app.kubernetes.io/name=mariadb-galera -n 950003-prod

# Step 2: Scale to zero (stops all crashing pods)
oc scale statefulset mariadb-galera --replicas=0 -n 950003-prod

# Step 3: Wait for all pods to terminate
oc get pods -l app.kubernetes.io/name=mariadb-galera -n 950003-prod -w
# Press Ctrl+C when all pods are gone

# Step 4: Delete secondary PVCs (forces clean state on secondaries)
# ⚠️  WARNING: This deletes galera-1 and galera-2 data
# Primary (galera-0) data is preserved
oc delete pvc data-mariadb-galera-1 -n 950003-prod
oc delete pvc data-mariadb-galera-2 -n 950003-prod

# Step 5: Fix galera-0 PVC if needed (set safe_to_bootstrap=1)
# This is needed if galera-0 also has safe_to_bootstrap: 0
# Create a debug pod to edit grastate.dat:

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: galera-pvc-fixer
  namespace: 950003-prod
spec:
  containers:
  - name: fixer
    image: busybox
    command: ['sh', '-c', 'sleep 3600']
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: data-mariadb-galera-0
EOF

# Wait for pod to be ready
oc wait --for=condition=Ready pod/galera-pvc-fixer -n 950003-prod --timeout=60s

# Set safe_to_bootstrap=1
oc exec galera-pvc-fixer -n 950003-prod -- sh -c "sed -i 's/safe_to_bootstrap: 0/safe_to_bootstrap: 1/' /data/grastate.dat"

# Verify the change
oc exec galera-pvc-fixer -n 950003-prod -- cat /data/grastate.dat

# Delete the fixer pod
oc delete pod galera-pvc-fixer -n 950003-prod

# Step 6: Scale back to original replica count
oc scale statefulset mariadb-galera --replicas=2 -n 950003-prod

# Step 7: Monitor recovery
oc get pods -l app.kubernetes.io/name=mariadb-galera -n 950003-prod -w
# Watch for all pods to become Running and Ready

# Step 8: Verify cluster health
oc exec mariadb-galera-0 -n 950003-prod -c mariadb-galera -- bash -c \
  'mysql -u root -p"$(cat /opt/bitnami/mariadb/secrets/mariadb-root-password)" -e "SHOW STATUS LIKE '\''wsrep_cluster%'\'';"'

# Expected output:
# wsrep_cluster_size: 2
# wsrep_cluster_status: Primary

# =============================================================================
# ALTERNATIVE: Quick recovery (if you're confident)
# =============================================================================

# One-liner (deletes secondary PVCs, scales down and up)
oc scale statefulset mariadb-galera --replicas=0 -n 950003-prod && \
  sleep 30 && \
  oc delete pvc data-mariadb-galera-1 data-mariadb-galera-2 -n 950003-prod && \
  oc scale statefulset mariadb-galera --replicas=2 -n 950003-prod

# =============================================================================
# EVEN FASTER: Nuclear option (deletes ALL PVCs - complete reset)
# =============================================================================
# ⚠️  USE ONLY IF: You have recent backup and can afford data loss
# This gives you a completely fresh cluster

oc scale statefulset mariadb-galera --replicas=0 -n 950003-prod && \
  sleep 30 && \
  oc delete pvc -l app.kubernetes.io/name=mariadb-galera -n 950003-prod && \
  oc scale statefulset mariadb-galera --replicas=2 -n 950003-prod

# Then restore from backup if needed
