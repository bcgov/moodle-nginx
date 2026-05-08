# Manual Mode Override for Pod Health Monitor

## Purpose

Prevents the automated pod-health-monitor from interfering with manual recovery operations, particularly during Galera split-brain resolution.

## Problem

When multiple healing systems operate simultaneously (automated + manual), they can conflict:
- Automated system scales StatefulSets while operator manually bootstraps nodes
- PVCs may be deleted/recreated during manual intervention
- Race conditions prevent cluster quorum formation
- "Competing healers" problem creates unstable state

## Solution

The `MANUAL_MODE` environment variable provides a kill-switch for all auto-healing actions.

### Behavior When Enabled

- ✅ Health checks continue (monitoring remains active)
- ✅ Error detection and logging persists
- ❌ Pod restarts disabled
- ❌ Galera auto-healing disabled
- ❌ PVC modifications disabled
- ❌ StatefulSet scaling prevented

## Usage

### Enable Manual Mode (Disable Auto-Healing)

```bash
oc set env deployment/pod-health-monitor MANUAL_MODE=true -n 950003-prod
```

Verify deployment restarts with new configuration:
```bash
oc get pods -l app=pod-health-monitor -n 950003-prod
# Wait for new pod to be Running
oc logs deployment/pod-health-monitor -n 950003-prod --tail=20
```

Expected output:
```
══════════════════════════════════════════════════════════════
⚠️  MANUAL MODE ENABLED ⚠️
══════════════════════════════════════════════════════════════
All auto-healing actions are DISABLED.
Pod health monitoring is READ-ONLY — manual intervention in progress.

To re-enable auto-healing:
  oc set env deployment/pod-health-monitor MANUAL_MODE=false -n 950003-prod
══════════════════════════════════════════════════════════════
```

### Perform Manual Recovery

With auto-healing disabled:

1. **Galera Split-Brain Recovery**:
   ```bash
   # Bootstrap from most advanced node
   oc exec -it mariadb-galera-0 -n 950003-prod -- \
     mysql -uroot -p"$DB_ROOT_PASSWORD" -e \
     "SET GLOBAL wsrep_provider_options='pc.bootstrap=YES';"

   # Scale up remaining nodes one-by-one
   oc scale statefulset mariadb-galera --replicas=1 -n 950003-prod
   # Wait for mariadb-galera-0 to be Ready, then:
   oc scale statefulset mariadb-galera --replicas=2 -n 950003-prod
   # Repeat incrementally to replicas=5
   ```

2. **Monitor Cluster Formation**:
   ```bash
   oc exec -it mariadb-galera-0 -n 950003-prod -- \
     mysql -uroot -p"$DB_ROOT_PASSWORD" -e \
     "SHOW STATUS LIKE 'wsrep_cluster_size';"
   ```

3. **Verify Quorum**:
   ```bash
   for i in {0..4}; do
     echo "=== mariadb-galera-$i ==="
     oc exec -it mariadb-galera-$i -n 950003-prod -- \
       mysql -uroot -p"$DB_ROOT_PASSWORD" -e \
       "SHOW STATUS LIKE 'wsrep_cluster_status';"
   done
   ```

### Re-Enable Auto-Healing

After manual recovery completes successfully:

```bash
oc set env deployment/pod-health-monitor MANUAL_MODE=false -n 950003-prod
```

Verify auto-healing resumed:
```bash
oc logs deployment/pod-health-monitor -n 950003-prod --tail=20 | grep -i "manual"
# Should NOT show "MANUAL MODE ENABLED" message
```

## When to Use Manual Mode

**Enable MANUAL_MODE=true when:**
- Performing Galera split-brain recovery
- Debugging persistent pod failures
- Testing configuration changes that may trigger false positives
- Executing maintenance that temporarily disrupts services
- Investigating cluster state without automated interference

**Disable MANUAL_MODE=false when:**
- Manual intervention complete
- Cluster stable and healthy
- Normal operations resume

## Safety Considerations

### Always Verify Mode State

Before manual operations:
```bash
oc get deployment pod-health-monitor -n 950003-prod -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MANUAL_MODE")].value}'
# Should output: true
```

After re-enabling:
```bash
oc get deployment pod-health-monitor -n 950003-prod -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MANUAL_MODE")].value}'
# Should output: false
```

### Monitoring Continues

Even with `MANUAL_MODE=true`:
- Error detection still runs
- Logs still record issues
- RocketChat notifications may still send (warning-level only)
- No automated corrective actions taken

### Temporary Override Only

**Do not leave manual mode enabled indefinitely:**
- Set a reminder to re-enable auto-healing
- Document manual mode activation in incident logs
- Review pod-health-monitor logs after re-enabling to catch any issues that occurred during manual mode

## Troubleshooting

### Manual Mode Not Taking Effect

**Symptom**: Auto-healing still active after setting `MANUAL_MODE=true`

**Diagnosis**:
```bash
# Check environment variable set correctly
oc get deployment pod-health-monitor -n 950003-prod -o yaml | grep -A2 MANUAL_MODE

# Verify pod restarted with new config
oc get pods -l app=pod-health-monitor -n 950003-prod -o wide
# Check AGE column — should be recent (< 2 minutes)
```

**Fix**: Force deployment rollout
```bash
oc rollout restart deployment/pod-health-monitor -n 950003-prod
oc rollout status deployment/pod-health-monitor -n 950003-prod
```

### Forgot to Disable Manual Mode

**Symptom**: Production issues not auto-healing, manual mode was enabled days ago

**Diagnosis**:
```bash
oc get deployment pod-health-monitor -n 950003-prod -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MANUAL_MODE")].value}'
```

**Fix**:
```bash
oc set env deployment/pod-health-monitor MANUAL_MODE=false -n 950003-prod
oc logs deployment/pod-health-monitor -n 950003-prod --tail=50
# Verify auto-healing resumed
```

### Manual Mode Shows in Logs But Auto-Healing Still Triggers

**Symptom**: Logs show "MANUAL MODE ENABLED" but pods still restart

**Diagnosis**: Check for multiple health monitor deployments or CronJobs
```bash
oc get all -l component=monitoring -n 950003-prod
oc get cronjobs -n 950003-prod | grep -i health
```

**Fix**: Ensure only one monitoring system active:
- Suspend legacy CronJobs: `oc patch cronjob <name> -p '{"spec": {"suspend": true}}' -n 950003-prod`
- Scale down duplicate deployments: `oc scale deployment <name> --replicas=0 -n 950003-prod`

## Related Documentation

- [Galera Monitoring Solution](galera-monitoring-solution.md) — Architecture and auto-healing design
- [Manual Galera Troubleshooting](manual-galera-troubleshooting.md) — Step-by-step recovery procedures
- [Pod Health Monitor Deployment](../openshift/scripts/README.md#deploy-health-monitor) — Installation and configuration

## Implementation Details

### Code Location

**Template**: [openshift/pod-health-monitor.yml](../openshift/pod-health-monitor.yml)
- Environment variable defined in container spec (default: `false`)

**Script**: [openshift/scripts/monitor-pods.sh](../openshift/scripts/monitor-pods.sh)
- Checks `MANUAL_MODE` at startup (displays banner if enabled)
- Guards pod restart logic (line ~175)
- Guards Galera auto-healing (line ~270)

### Design Rationale

**Why environment variable instead of ConfigMap?**
- Faster changes (no ConfigMap propagation delay)
- Single command enables/disables
- Explicit deployment rollout (no ambiguity about when change applies)

**Why not suspend the deployment entirely?**
- Keep monitoring active (visibility into cluster state)
- Preserve error logging (root cause analysis)
- Faster re-enablement (no cold-start delay)

**Why default to `false`?**
- Auto-healing is the normal operational mode
- Forces explicit action to disable safety systems
- Prevents accidental "always manual" deployments
