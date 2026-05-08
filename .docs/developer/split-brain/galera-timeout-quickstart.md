# Quick Start: Deploy Galera Timeout Configuration

## Context

This guide implements **Tier 1** of the [Galera Testing Strategy](galera-testing-strategy.md): deploying timeout increases to prevent split-brain issues.

---

## What This Fixes

**Problem**: Production Galera cluster experiences split-brain due to aggressive default timeouts (15s) that don't tolerate transient network latency in OpenShift SDN.

**Solution**: Increase timeouts to 30s via `wsrep_provider_options`, allowing cluster to survive temporary network hiccups without false node evictions.

**Expected Outcome**: Zero split-brain events caused by transient network issues.

---

## Implementation Steps

### Step 1: Update Deployment Script

Add timeout configuration to [openshift/scripts/deploy-mariadb-galera.sh](../openshift/scripts/deploy-mariadb-galera.sh).

**Location 1: Helm Upgrade (Bootstrap Phase) — Line ~353**

Find the first `helm upgrade` command (around line 340-360):
```bash
helm_upgrade_response=$(helm upgrade $DB_DEPLOYMENT_NAME \
  oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --set image.registry=$RESOLVED_IMAGE_REGISTRY \
  --set image.repository=$RESOLVED_IMAGE_REPOSITORY \
  ...
  --set replicaCount=1 \
  --reuse-values 2>&1)
```

Add BEFORE `--reuse-values`:
```bash
  --set 'extraFlags=--wsrep-provider-options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT1S;evs.keepalive_period=PT2S;evs.join_retrans_period=PT2S;gcs.fc_limit=256;gcs.fc_factor=0.5"' \
  --reuse-values 2>&1)
```

**Location 2: Helm Upgrade (Scale Phase) — Line ~389**

Find the second `helm upgrade` command (around line 387-395):
```bash
helm upgrade $DB_DEPLOYMENT_NAME \
  oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --set galera.bootstrap.forceBootstrap=false \
  --set galera.bootstrap.forceSafeToBootstrap=false \
  --set replicaCount=$DB_REPLICAS \
  --reuse-values
```

Change to:
```bash
helm upgrade $DB_DEPLOYMENT_NAME \
  oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --set galera.bootstrap.forceBootstrap=false \
  --set galera.bootstrap.forceSafeToBootstrap=false \
  --set replicaCount=$DB_REPLICAS \
  --set 'extraFlags=--wsrep-provider-options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT1S;evs.keepalive_period=PT2S;evs.join_retrans_period=PT2S;gcs.fc_limit=256;gcs.fc_factor=0.5"' \
  --reuse-values
```

**Location 3: Helm Install (Fresh Install) — Line ~416**

Find the `helm install` command (around line 416-460):
```bash
helm install $DB_DEPLOYMENT_NAME \
  oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --set image.registry=$RESOLVED_IMAGE_REGISTRY \
  ...
```

Add AFTER the existing `--set` flags, BEFORE the closing of the command:
```bash
  --set 'extraFlags=--wsrep-provider-options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT1S;evs.keepalive_period=PT2S;evs.join_retrans_period=PT2S;gcs.fc_limit=256;gcs.fc_factor=0.5"'
```

---

### Step 2: Test in Dev Environment

```bash
# Navigate to scripts directory
cd c:\UwAmp\www\moodle-nginx\openshift\scripts

# Ensure namespace set correctly
$env:DEPLOY_NAMESPACE = "950003-dev"

# Run deployment
.\deploy-mariadb-galera.sh
```

**Expected Output:**
```
Helm upgrade (bootstrap) submitted...
Waiting for mariadb-galera-0 to bootstrap...
   mariadb-galera-0 is Ready (bootstrapped as primary)
Scaling to 2 replicas (forceBootstrap=false)...
Helm upgrade submitted -- secondaries will SST from galera-0
```

---

### Step 3: Validate Configuration Applied

```bash
# Check wsrep_provider_options in running pod
oc exec -it mariadb-galera-0 -n 950003-dev -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW VARIABLES LIKE 'wsrep_provider_options';"
```

**Search for specific setting:**
```bash
oc exec -it mariadb-galera-0 -n 950003-dev -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW VARIABLES LIKE 'wsrep_provider_options';" | grep inactive_timeout
```

**Expected Result:**
```
evs.inactive_timeout=PT30S
```

If you see `PT15S` or no output, the configuration didn't apply — check helm values:
```bash
helm get values mariadb-galera -n 950003-dev
```

---

### Step 4: Monitor for Issues

**Check pod logs for errors:**
```bash
oc logs -f mariadb-galera-0 -n 950003-dev | grep -i "error\|warning\|timeout"
```

**Verify cluster health:**
```bash
for i in {0..1}; do
  echo "=== mariadb-galera-$i ==="
  oc exec -it mariadb-galera-$i -n 950003-dev -- \
    mysql -uroot -p"$DB_ROOT_PASSWORD" \
    -e "SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_cluster_status';"
done
```

**Expected:**
```
=== mariadb-galera-0 ===
wsrep_cluster_size    | 2
wsrep_cluster_status  | Primary

=== mariadb-galera-1 ===
wsrep_cluster_size    | 2
wsrep_cluster_status  | Primary
```

---

### Step 5: Run Chaos Test (Optional but Recommended)

**Inject network latency to simulate SDN jitter:**
```bash
# Add 100ms latency to mariadb-galera-0
oc exec -it mariadb-galera-0 -n 950003-dev -- bash -c '
  tc qdisc add dev eth0 root netem delay 100ms 20ms
'

# Wait 60 seconds (should survive with new timeout)
Start-Sleep -Seconds 60

# Check cluster status
oc exec -it mariadb-galera-0 -n 950003-dev -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_status';"

# Remove latency
oc exec -it mariadb-galera-0 -n 950003-dev -- bash -c '
  tc qdisc del dev eth0 root
'
```

**Expected**: Cluster status remains `Primary` (no split-brain).

---

### Step 6: Deploy to Test Environment

If dev deployment successful:

```bash
# Switch namespace
$env:DEPLOY_NAMESPACE = "950003-test"

# Run deployment
.\deploy-mariadb-galera.sh

# Validate configuration (same as Step 3)
oc exec -it mariadb-galera-0 -n 950003-test -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW VARIABLES LIKE 'wsrep_provider_options';" | grep inactive_timeout
```

---

### Step 7: Production Deployment (After Validation)

**Prerequisites:**
1. ✅ Dev deployment successful (no errors)
2. ✅ Test deployment successful (no errors)
3. ✅ Chaos testing passed (optional but recommended)
4. ✅ Change management approval obtained
5. ✅ Maintenance window scheduled

**Production Rollout:**

```bash
# Enable MANUAL_MODE on pod-health-monitor (prevent interference)
oc set env deployment/pod-health-monitor MANUAL_MODE=true -n 950003-prod

# Verify manual mode enabled
oc logs deployment/pod-health-monitor -n 950003-prod --tail=20 | Select-String "MANUAL MODE"

# Deploy timeout configuration
$env:DEPLOY_NAMESPACE = "950003-prod"
.\deploy-mariadb-galera.sh

# Wait for rolling restart to complete (one pod at a time)
oc get pods -l app.kubernetes.io/name=mariadb-galera -n 950003-prod -w

# Validate configuration on each pod
for ($i=0; $i -lt 5; $i++) {
  Write-Host "=== Checking mariadb-galera-$i ==="
  oc exec -it mariadb-galera-$i -n 950003-prod -- \
    mysql -uroot -p"$env:DB_ROOT_PASSWORD" \
    -e "SHOW VARIABLES LIKE 'wsrep_provider_options';" | Select-String "inactive_timeout"
}

# Verify cluster health (all 5 nodes in sync)
oc exec -it mariadb-galera-0 -n 950003-prod -- \
  mysql -uroot -p"$env:DB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_cluster_status';"

# Expected:
# wsrep_cluster_size    | 5
# wsrep_cluster_status  | Primary

# Re-enable pod-health-monitor auto-healing
oc set env deployment/pod-health-monitor MANUAL_MODE=false -n 950003-prod
```

---

## Rollback Procedure

If issues occur after deployment:

### Quick Rollback (Remove Timeout Configuration)

```bash
# Remove extraFlags from helm values
helm upgrade mariadb-galera \
  oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --reset-values \
  --reuse-values

# Restart pods to pick up default timeouts
oc delete pod mariadb-galera-0 -n <namespace>
# Wait for pod to be Ready, then continue with remaining pods one-by-one
```

### Full Rollback (Previous Helm Release)

```bash
# List recent releases
helm history mariadb-galera -n <namespace>

# Rollback to previous revision
helm rollback mariadb-galera <revision-number> -n <namespace>
```

---

## Troubleshooting

### Issue: Timeout Configuration Not Applied

**Symptom**: `grep inactive_timeout` shows `PT15S` or no output

**Diagnosis:**
```bash
helm get values mariadb-galera -n <namespace> | Select-String "extraFlags"
```

**Possible Causes:**
1. `--set extraFlags` not properly quoted (bash escaping issue)
2. `--reuse-values` overriding the setting (Helm precedence)
3. Pods haven't restarted yet (configuration cached)

**Fix:**
```bash
# Force helm to apply new configuration
helm upgrade mariadb-galera \
  oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --set 'extraFlags=--wsrep-provider-options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT1S;evs.keepalive_period=PT2S;evs.join_retrans_period=PT2S;gcs.fc_limit=256;gcs.fc_factor=0.5"' \
  --reuse-values \
  -n <namespace>

# Manually restart pods to pick up change
oc delete pod mariadb-galera-0 -n <namespace>
```

---

### Issue: Cluster Split-Brain During Deployment

**Symptom**: `wsrep_cluster_size` shows different values on different pods

**Diagnosis:**
```bash
for ($i=0; $i -lt 5; $i++) {
  Write-Host "=== mariadb-galera-$i ==="
  oc exec -it mariadb-galera-$i -n <namespace> -- \
    mysql -uroot -p"$env:DB_ROOT_PASSWORD" \
    -e "SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_cluster_status';"
}
```

**Recovery:**
```bash
# Enable MANUAL_MODE on pod-health-monitor
oc set env deployment/pod-health-monitor MANUAL_MODE=true -n <namespace>

# Scale to 1 replica (galera-0 becomes primary)
oc scale statefulset mariadb-galera --replicas=1 -n <namespace>

# Wait for galera-0 to be sole member
oc exec -it mariadb-galera-0 -n <namespace> -- \
  mysql -uroot -p"$env:DB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Should show: 1

# Bootstrap from galera-0
oc exec -it mariadb-galera-0 -n <namespace> -- \
  mysql -uroot -p"$env:DB_ROOT_PASSWORD" \
  -e "SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';"

# Scale back up one-by-one
oc scale statefulset mariadb-galera --replicas=2 -n <namespace>
# Wait, verify, then continue to 3, 4, 5...

# Disable MANUAL_MODE when complete
oc set env deployment/pod-health-monitor MANUAL_MODE=false -n <namespace>
```

---

## Success Criteria

✅ Configuration validated on all Galera pods (wsrep_provider_options shows new timeouts)
✅ Cluster size stable at expected replica count (2 in dev/test, 5 in prod)
✅ No "connection timeout" errors in logs for 48 hours
✅ No split-brain events during normal operations
✅ Graceful pod restarts complete without cluster disruption

---

## Next Steps After Deployment

1. **Monitor** production for 1 week
   - Watch for split-brain events (should be zero)
   - Check logs for timeout-related errors
   - Verify cluster_size remains stable at 5

2. **Document** in runbooks
   - Add timeout configuration to standard deployment procedures
   - Update incident response playbooks
   - Record success/failure in change log

3. **Proceed to Tier 2** (Chaos Testing)
   - See [Galera Testing Strategy](galera-testing-strategy.md#tier-2-chaos-engineering-in-dev)
   - Validate configuration under simulated network failures
   - Build confidence in resilience improvements

---

## Reference

- **Timeout Configuration Details**: [config/mariadb/galera-timeouts.yaml](../config/mariadb/galera-timeouts.yaml)
- **Full Testing Strategy**: [docs/galera-testing-strategy.md](galera-testing-strategy.md)
- **Manual Override Procedures**: [docs/manual-mode-override.md](manual-mode-override.md)
- **Galera Parameter Reference**: https://galeracluster.com/library/documentation/galera-parameters.html
