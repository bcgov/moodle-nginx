# Manual: MariaDB Galera Split-Brain Detection and Resolution

This guide provides step-by-step manual procedures for detecting and resolving MariaDB Galera cluster split-brain scenarios in OpenShift environments. These procedures mirror the automated processes implemented in the monitoring scripts.

## Prerequisites

### 1. OpenShift Access

1. Log into the OpenShift Console at: https://console.apps.silver.devops.gov.bc.ca
2. Click your username in the top right corner
3. Select **"Copy login command"**
4. Click **"Display Token"**
5. Copy the `oc login` command (it will look like):

   ```bash
   oc login --token=sha256~<SECRET_KEY> --server=https://api.silver.devops.gov.bc.ca:6443
   ```

### 2. Terminal Setup

1. Open Windows Command Prompt or PowerShell
2. Paste and execute the login command
3. Set your project namespace:

   ```bash
   oc project 950003-prod
   ```

## Quick Health Check

### Check All Running Pods

```bash
# Get all running pods in the namespace (test access)
oc get pods --field-selector=status.phase=Running

# Check MariaDB Galera pods specifically
oc get pods -l "app.kubernetes.io/name=mariadb-galera" --field-selector=status.phase=Running

# Check other critical services
oc get pods -l "deployment=php" --field-selector=status.phase=Running
oc get pods -l "app=redis-proxy" --field-selector=status.phase=Running
```

## Detailed Galera Cluster Health Assessment

### 1. Identify Galera Pods

```bash
# Get Galera pod names
oc get pods -l "app.kubernetes.io/name=mariadb-galera" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}'

# Get detailed pod information
oc get pods -l "app.kubernetes.io/name=mariadb-galera" -o wide
```

### 2. Check Galera Cluster Status

For each Galera pod, check the cluster status. Replace `<POD_NAME>` with actual pod names from step 1:

```bash
# Get environment variables (needed for MySQL access)
# For PowerShell users:
$env:MARIADB_USER = oc get secret mariadb-galera -o jsonpath='{.data.mariadb-username}' | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}
$env:MARIADB_PASSWORD = oc get secret mariadb-galera -o jsonpath='{.data.mariadb-password}' | %{[System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_))}

# For Command Prompt users (simpler approach):
# You'll need to decode the base64 values manually or use the actual username/password directly

# Check if MySQL is responsive on each pod
oc exec -it <POD_NAME> -- mysqladmin -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" ping

# Get detailed Galera status for each pod
oc exec -it <POD_NAME> -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size', 'wsrep_cluster_state_uuid');"
```

### 3. Example Health Check for Multiple Pods

Run these commands for each pod (replace `mariadb-galera-0`, `mariadb-galera-1`, etc. with your actual pod names):

```bash
# Pod 0
echo "=== Checking mariadb-galera-0 ==="
oc exec -it mariadb-galera-0 -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size', 'wsrep_cluster_state_uuid');"

# Pod 1
echo "=== Checking mariadb-galera-1 ==="
oc exec -it mariadb-galera-1 -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size', 'wsrep_cluster_state_uuid');"

# Pod 2
echo "=== Checking mariadb-galera-2 ==="
oc exec -it mariadb-galera-2 -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size', 'wsrep_cluster_state_uuid');"

# Continue for all pods...
```

## Split-Brain Detection

### Healthy Cluster Indicators

A healthy cluster should show:

- **wsrep_cluster_status**: `Primary`
- **wsrep_local_state_comment**: `Synced`
- **wsrep_cluster_size**: Same number across all pods (e.g., `5`)
- **wsrep_cluster_state_uuid**: Same UUID across all pods

### Split-Brain Indicators

🚨 **Split-brain detected if you see:**

- Different `wsrep_cluster_state_uuid` values across pods
- Different `wsrep_cluster_size` values across pods
- Some pods showing `wsrep_cluster_status` as `non-primary`
- Some pods showing `wsrep_local_state_comment` as `Disconnected`

### Example Split-Brain Output

```
Pod 1: wsrep_cluster_state_uuid = 12345-abcd, wsrep_cluster_size = 2
Pod 2: wsrep_cluster_state_uuid = 12345-abcd, wsrep_cluster_size = 2
Pod 3: wsrep_cluster_state_uuid = 67890-efgh, wsrep_cluster_size = 3
Pod 4: wsrep_cluster_state_uuid = 67890-efgh, wsrep_cluster_size = 3
Pod 5: wsrep_cluster_state_uuid = 67890-efgh, wsrep_cluster_size = 3
```
This shows two separate clusters with different UUIDs☝️

## Manual Split-Brain Resolution

### ⚠️ Important Warnings

- **ALWAYS take a database backup before attempting resolution**
- **Coordinate with your team** - ensure no other maintenance is happening
- **Document the issue** - note which pods were affected and the symptoms
- **Monitor closely** - watch the process and be ready to rollback

### Step 1: Create a Database Backup

```bash
# Find a healthy pod for backup (one that shows 'Primary' and 'Synced')
oc exec -it mariadb-galera-0 -- mysqldump -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" --all-databases --single-transaction > galera-backup-$(date +%Y%m%d-%H%M).sql

# Verify backup was created
ls -la galera-backup-*.sql
```

### Step 2: Identify the StatefulSet

```bash
# Get StatefulSet information
oc get statefulset -l "app.kubernetes.io/name=mariadb-galera"

# Get current replica count
oc get statefulset mariadb-galera -o jsonpath='{.spec.replicas}'
```

### Step 3: Scale Down to 1 Replica (Establish Primary)

```bash
# Get original replica count first
ORIGINAL_REPLICAS=$(oc get statefulset mariadb-galera -o jsonpath='{.spec.replicas}')
echo "Original replica count: $ORIGINAL_REPLICAS"

# Scale down to 1 replica
oc scale statefulset mariadb-galera --replicas=1

# Wait for scaling to complete (this may take a few minutes)
oc get pods -l "app.kubernetes.io/name=mariadb-galera" -w
```

### Step 4: Verify Single Node is Healthy

```bash
# Wait for the remaining pod to be ready
oc wait --for=condition=ready pod -l "app.kubernetes.io/name=mariadb-galera" --timeout=300s

# Check the remaining pod's status
REMAINING_POD=$(oc get pods -l "app.kubernetes.io/name=mariadb-galera" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}')
echo "Remaining pod: $REMAINING_POD"

# Verify it's healthy and in Primary state
oc exec -it $REMAINING_POD -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size');"
```

Expected output should show:

- wsrep_cluster_status: `Primary`
- wsrep_local_state_comment: `Synced`
- wsrep_cluster_size: `1`

### Step 5: Scale Back Up to Original Replica Count

```bash
# Scale back up to original size
oc scale statefulset mariadb-galera --replicas=$ORIGINAL_REPLICAS

# Monitor the scaling process
oc get pods -l "app.kubernetes.io/name=mariadb-galera" -w
```

### Step 6: Verify Cluster Recovery

Wait for all pods to be Running, then check cluster health:

```bash
# Wait for all pods to be ready
oc wait --for=condition=ready pod -l "app.kubernetes.io/name=mariadb-galera" --timeout=600s

# Get all pod names
GALERA_PODS=$(oc get pods -l "app.kubernetes.io/name=mariadb-galera" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')

# Check each pod's status
for pod in $GALERA_PODS; do
  echo "=== Checking $pod ==="
  oc exec -it $pod -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size', 'wsrep_cluster_state_uuid');"
  echo ""
done
```

### Step 7: Validate Full Recovery

All pods should now show:

- **wsrep_cluster_status**: `Primary`
- **wsrep_local_state_comment**: `Synced`
- **wsrep_cluster_size**: Same value (your original replica count)
- **wsrep_cluster_state_uuid**: Same UUID across all pods

## Pod Log Analysis

### Check for Error Patterns

```bash
# Check recent logs for MariaDB errors
oc logs mariadb-galera-0 --tail=50
oc logs mariadb-galera-1 --tail=50
# oc logs mariadb-galera-2, 3, 4, 5, etc...

# Check for PHP application errors
# First get the pod names
oc get pods -l "deployment=php" --field-selector=status.phase=Running -o jsonpath="{.items[*].metadata.name}"

# Then check logs for each pod individually (replace <PHP_POD_NAME> with actual names from above)
oc logs <PHP_POD_NAME> --tail=50

# Check Redis Proxy errors
# First get the pod names
oc get pods -l "app=redis-proxy" --field-selector=status.phase=Running -o jsonpath="{.items[*].metadata.name}"

# Then check logs for each pod individually (replace <REDIS_POD_NAME> with actual names from above)
oc logs <REDIS_POD_NAME> --tail=50 | findstr /i "err:"
```

### Restart Problematic Pods

If you find pods with errors:

```bash
# Restart a specific pod by deleting it (it will be recreated)
oc delete pod <POD_NAME>

# Example: Restart a PHP pod with errors
oc delete pod php-deployment-12345-abcde

# Monitor the restart
oc get pods -w
```

### Log Analysis

For more complex log analysis on Windows, you can use PowerShell:

```powershell
# PowerShell method to check multiple PHP pods for errors
$phpPods = (oc get pods -l "deployment=php" --field-selector=status.phase=Running -o jsonpath="{.items[*].metadata.name}") -split " "
foreach ($pod in $phpPods) {
    Write-Host "=== Checking $pod ==="
    oc logs $pod --tail=50 | Select-String -Pattern "error|critical" -CaseSensitive:$false
}

# PowerShell method to check Redis Proxy pods
$redisPods = (oc get pods -l "app=redis-proxy" --field-selector=status.phase=Running -o jsonpath="{.items[*].metadata.name}") -split " "
foreach ($pod in $redisPods) {
    Write-Host "=== Checking Redis pod $pod ==="
    oc logs $pod --tail=50 | Select-String -Pattern "err:" -CaseSensitive:$false
}
```

### Command Prompt Alternative

If using Command Prompt (not PowerShell), use this step-by-step approach:

```cmd
REM Get PHP pod names first
oc get pods -l "deployment=php" --field-selector=status.phase=Running -o jsonpath="{.items[*].metadata.name}"

REM Copy each pod name and check logs manually
oc logs <PHP_POD_NAME_1> --tail=50 | findstr /i "error critical"
oc logs <PHP_POD_NAME_2> --tail=50 | findstr /i "error critical"

REM Same for Redis pods
oc get pods -l "app=redis-proxy" --field-selector=status.phase=Running -o jsonpath="{.items[*].metadata.name}"
oc logs <REDIS_POD_NAME_1> --tail=50 | findstr /i "err:"
oc logs <REDIS_POD_NAME_2> --tail=50 | findstr /i "err:"
```

## Troubleshooting Common Issues

### Issue: Pods Stuck in Pending or Init State

```bash
# Check pod events for scheduling issues
oc describe pod <POD_NAME>

# Check resource availability
oc describe nodes

# Check PVC status
oc get pvc
```

### Issue: Pods Keep Restarting

```bash
# Check restart count
oc get pods -l "app.kubernetes.io/name=mariadb-galera"

# Get detailed restart reason
oc describe pod <POD_NAME>

# Check resource limits
oc get statefulset mariadb-galera -o yaml | grep -A 10 resources
```

### Issue: MySQL Connection Refused

```bash
# Check if MySQL process is running in pod
oc exec -it <POD_NAME> -- ps aux | grep mysql

# Check MySQL error logs
oc exec -it <POD_NAME> -- tail -50 /var/log/mysql/error.log

# Check network connectivity between pods
oc exec -it <POD_NAME> -- ping <OTHER_POD_IP>
```

## Emergency Procedures

### Complete Cluster Failure Recovery

If all pods are failing and split-brain resolution doesn't work:

```bash
# 1. Scale down to 0 (DANGEROUS - only if cluster is completely broken)
oc scale statefulset mariadb-galera --replicas=0

# 2. Wait for all pods to terminate
oc get pods -l "app.kubernetes.io/name=mariadb-galera" -w

# 3. Backup any recoverable data from PVCs if possible
oc get pvc

# 4. Scale back up with fresh cluster
oc scale statefulset mariadb-galera --replicas=1

# 5. Wait for first pod to initialize
oc wait --for=condition=ready pod -l "app.kubernetes.io/name=mariadb-galera" --timeout=600s

# 6. Restore from backup
# oc exec -it <POD_NAME> -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" < galera-backup-YYYYMMDD-HHMM.sql

# 7. Scale up to full size
oc scale statefulset mariadb-galera --replicas=$ORIGINAL_REPLICAS
```

## Prevention and Best Practices

### Regular Health Checks

Run these commands regularly to catch issues early:

```bash
# Weekly health check script
echo "=== Galera Cluster Health Check - $(date) ==="
GALERA_PODS=$(oc get pods -l "app.kubernetes.io/name=mariadb-galera" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}')
for pod in $GALERA_PODS; do
  echo "Checking $pod:"
  oc exec -it $pod -- mysql -u "$MARIADB_USER" -p"$MARIADB_PASSWORD" -e "SHOW STATUS WHERE Variable_name IN ('wsrep_cluster_status', 'wsrep_local_state_comment', 'wsrep_cluster_size');" 2>/dev/null || echo "  ERROR: Cannot connect to MySQL on $pod"
  echo ""
done
```

> **Note**: This manual process mirrors the automated monitoring and healing to be implemented in the pod health monitoring system. The automated system performs these same checks every 60 seconds and auto-heals when safe to do so. Manual intervention should only be necessary when the automated system cannot resolve the issue.
