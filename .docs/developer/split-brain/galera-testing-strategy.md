# Galera Testing & Validation Strategy

## Executive Summary

**Problem**: Production split-brain issues cannot be easily replicated in dev/test (2 replicas) vs prod (5 replicas). Simply scaling dev to 5 replicas with lower CPU would create different failure modes (CPU starvation timeouts) that don't match production's network-related issues.

**Solution**: Multi-tiered testing strategy combining configuration hardening, chaos engineering, and targeted stress testing. Focus on making the system resilient to split-brain rather than preventing it entirely.

---

## Tier 1: Configuration Hardening (Zero Risk, High Value)

**Deploy timeout increases across ALL environments** before attempting replication testing.

### Implementation

1. **Add timeout configuration to deployment script**:

   Edit [openshift/scripts/deploy-mariadb-galera.sh](../openshift/scripts/deploy-mariadb-galera.sh):
   ```bash
   # After existing --set flags, add:
   --set 'extraFlags=--wsrep-provider-options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT1S;evs.keepalive_period=PT2S;evs.join_retrans_period=PT2S;gcs.fc_limit=256;gcs.fc_factor=0.5"'
   ```

2. **Deploy to dev first**:
   ```bash
   cd openshift/scripts
   ./deploy-mariadb-galera.sh
   ```

3. **Validate settings applied**:
   ```bash
   oc exec -it mariadb-galera-0 -n 950003-dev -- \
     mysql -uroot -p"$DB_ROOT_PASSWORD" \
     -e "SHOW VARIABLES LIKE 'wsrep_provider_options';" | grep inactive_timeout
   # Should show: evs.inactive_timeout=PT30S
   ```

4. **Monitor for 48 hours in dev** (look for improvements):
   - No "connection timeout" messages in logs
   - Cluster survives pod restarts gracefully
   - No NON-PRIMARY view transitions

5. **Promote to test → prod** (following standard change management)

**Why This First?**:
- Zero downtime (rolling restart)
- Low risk (can rollback by removing --set flag)
- Benefits ALL environments equally
- Addresses root cause (aggressive timeouts) directly

---

## Tier 2: Chaos Engineering in Dev (Simulate Network Issues)

**Use network manipulation to artificially create split-brain conditions** without needing 5 replicas.

### Approach: Network Latency Injection

```bash
# On arbitrary dev node, introduce 100ms latency to simulate SDN jitter
oc exec -it mariadb-galera-0 -n 950003-dev -- bash -c '
  tc qdisc add dev eth0 root netem delay 100ms 20ms
'

# Monitor cluster health during latency
oc exec -it mariadb-galera-0 -n 950003-dev -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_status';"

# Remove latency after test
oc exec -it mariadb-galera-0 -n 950003-dev -- bash -c '
  tc qdisc del dev eth0 root
'
```

### Approach: Packet Loss Injection

```bash
# Introduce 2% packet loss (simulates congested network)
oc exec -it mariadb-galera-0 -n 950003-dev -- bash -c '
  tc qdisc add dev eth0 root netem loss 2%
'

# Check if cluster stays in sync
for i in {0..1}; do
  oc exec -it mariadb-galera-$i -n 950003-dev -- \
    mysql -uroot -p"$DB_ROOT_PASSWORD" \
    -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"
done
```

### Approach: Temporary Network Partition

```bash
# Block Galera replication port (4567) between nodes
oc exec -it mariadb-galera-0 -n 950003-dev -- bash -c '
  iptables -A INPUT -p tcp --dport 4567 -j DROP
'

# Wait 35 seconds (should survive with new evs.inactive_timeout=PT30S)
sleep 35

# Restore connectivity
oc exec -it mariadb-galera-0 -n 950003-dev -- bash -c '
  iptables -D INPUT -p tcp --dport 4567 -j DROP
'

# Verify cluster recovered
oc exec -it mariadb-galera-0 -n 950003-dev -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW STATUS LIKE 'wsrep_cluster_size';"
```

**Expected Outcomes**:
- ✅ With old timeouts (PT15S): cluster enters split-brain
- ✅ With new timeouts (PT30S): cluster survives transient partition

**Advantages**:
- Tests actual network resilience (the real problem in prod)
- Works in 2-replica dev environment
- Repeatable and controlled
- No resource waste

---

## Tier 3: Load Testing (Stress Test Split-Brain Recovery)

**Validate that cluster can handle production-like load** during recovery scenarios.

### Tool: Sysbench

```bash
# Install sysbench in test pod
oc run mysql-load-test --image=severalnines/sysbench:latest \
  -n 950003-dev --command -- sleep infinity

# Prepare test database
oc exec -it mysql-load-test -n 950003-dev -- \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=mariadb-galera-headless \
  --mysql-port=3306 \
  --mysql-user=$DB_USER \
  --mysql-password=$DB_PASSWORD \
  --mysql-db=$DB_NAME \
  --tables=10 \
  --table-size=10000 \
  prepare

# Run sustained load (simulates production traffic)
oc exec -it mysql-load-test -n 950003-dev -- \
  sysbench /usr/share/sysbench/oltp_read_write.lua \
  --mysql-host=mariadb-galera-headless \
  --mysql-port=3306 \
  --mysql-user=$DB_USER \
  --mysql-password=$DB_PASSWORD \
  --mysql-db=$DB_NAME \
  --tables=10 \
  --table-size=10000 \
  --threads=4 \
  --time=300 \
  --report-interval=10 \
  run
```

### Concurrent Chaos Test

```bash
# In one terminal: run sysbench load
oc exec -it mysql-load-test -n 950003-dev -- \
  sysbench /usr/share/sysbench/oltp_read_write.lua ... run

# In another terminal: restart a Galera pod during load
oc delete pod mariadb-galera-0 -n 950003-dev

# Monitor load test results — should show minimal transaction failures
```

**Success Criteria**:
- Transaction error rate < 1% during pod restart
- Cluster recovers to full capacity within 60 seconds
- No split-brain (all nodes show same wsrep_cluster_size)

---

## Tier 4: Controlled 5-Replica Testing (If Budget Allows)

**Option A: Temporary Scale-Up in Test Environment**

```bash
# Scale test to 5 replicas temporarily (e.g., Friday afternoon → Monday morning)
# Use SAME CPU as production to avoid false failures

# Step 1: Update CSV
# openshift/950003-test-sizing.csv:
# mariadb-galera,sts,5,5,5,7168,100,0,256,0,0
#                      ^ match prod CPU (100m, not 60m)

# Step 2: Deploy
cd openshift/scripts
./deploy-mariadb-galera.sh

# Step 3: Run chaos tests on 5-node cluster
# (use Tier 2 network injection tests)

# Step 4: Scale back down
# Restore CSV to 2 replicas before Monday
```

**Pros**:
- Exact replica count match to production
- Same CPU allocation (no false CPU starvation)
- Tests actual multi-path network failure scenarios

**Cons**:
- Temporary resource usage (5 pods @ 100m = 500m vs 2 @ 60m = 120m)
- PVC expansion required (need 5 PVCs instead of 2)
- Scheduling risk (may not fit in test namespace quota)

**When to Use**:
- Before major production changes (e.g., Galera version upgrade)
- After chaos testing shows promising results in 2-replica dev
- As final validation before prod deployment

---

**Option B: Dedicated Staging Environment (Long-Term Investment)**

Create `950003-staging` namespace with production-identical sizing:

```yaml
# openshift/950003-staging-sizing.csv
Deployment,Type,Pod Count,Max Pods,PVC Count,PVC Capacity (MiB),CPU Request (m),CPU Limit (m),Mem. Request (MiB),Mem. Limit (MiB),CPU Scale Value
mariadb-galera,sts,5,5,5,6144,100,0,256,0,0
# Exact mirror of 950003-prod-sizing.csv
```

**Pros**:
- Permanent production-like environment
- Can run long-duration tests (soak testing)
- Validates operational procedures (runbooks, playbooks)

**Cons**:
- Significant resource commitment (same as production)
- Additional maintenance overhead
- May not be feasible with current quota limits

**When to Consider**:
- If split-brain issues persist after Tier 1-3 interventions
- If business requires higher confidence in production changes
- If Platform Services grants additional quota allocation

---

## Tier 5: Production Monitoring & Gradual Rollout

**Deploy with incremental confidence-building.**

### Phase 1: Canary Deployment (Single Node)

```bash
# Apply timeout config to production, rolling restart one-by-one
cd openshift/scripts
./deploy-mariadb-galera.sh  # with new extraFlags

# Monitor first pod extensively
oc logs -f mariadb-galera-0 -n 950003-prod | grep -i "timeout\|non-prim\|view"

# Wait 24 hours before continuing rollout
```

### Phase 2: Observability Enhancement

**Add detailed Galera metrics to monitoring:**

```bash
# Create ServiceMonitor for Galera-specific metrics
# Track:
#   - wsrep_cluster_size (should always = 5)
#   - wsrep_cluster_status (should always = Primary)
#   - wsrep_local_state_comment (should always = Synced)
#   - wsrep_flow_control_paused (should be near 0)

# Alert thresholds:
wsrep_cluster_size != 5          # CRITICAL: Split-brain or node failure
wsrep_cluster_status != "Primary" # CRITICAL: Cluster non-operational
wsrep_flow_control_paused > 0.1   # WARNING: Replication lag building
```

### Phase 3: Runbook Testing

**Practice recovery procedures with new timeouts:**

1. **Graceful Node Restart** (maintenance scenario):
   ```bash
   # Should complete without triggering split-brain
   oc delete pod mariadb-galera-0 -n 950003-prod
   # Monitor: cluster_size should stay 5 (briefly 4 during restart)
   ```

2. **Ungraceful Node Failure** (crash simulation):
   ```bash
   # Kill mariabackup process to simulate unclean shutdown
   oc exec -it mariadb-galera-0 -n 950003-prod -- killall -9 mariadbd
   # Monitor: cluster should evict node after 30s (new timeout), not 15s
   ```

3. **Manual Bootstrap Recovery** (with MANUAL_MODE enabled):
   ```bash
   # Verify pod-health-monitor doesn't interfere
   oc set env deployment/pod-health-monitor MANUAL_MODE=true -n 950003-prod
   # Perform bootstrap test
   # Re-enable automation
   oc set env deployment/pod-health-monitor MANUAL_MODE=false -n 950003-prod
   ```

---

## Recommendations Summary

### Immediate Actions (This Week)

1. ✅ **Deploy Galera timeout increases** to dev → test → prod
   - File: [config/mariadb/galera-timeouts.yaml](../config/mariadb/galera-timeouts.yaml)
   - Script: Update deploy-mariadb-galera.sh with `--set extraFlags`
   - Validation: Check wsrep_provider_options in running pods

2. ✅ **Enable pod-health-monitor MANUAL_MODE** in runbooks
   - Document when to use (before manual intervention)
   - Practice enabling/disabling in dev
   - Add to incident response procedures

### Short-Term Actions (Next 2 Weeks)

3. 🔧 **Chaos testing in dev** (Tier 2)
   - Network latency injection test
   - Packet loss tolerance test
   - Partition recovery test
   - Document results in repository (./docs/chaos-testing-results.md)

4. 🔧 **Load testing with sysbench** (Tier 3)
   - Baseline performance metrics
   - Pod restart under load test
   - Multi-node failure simulation

### Medium-Term Actions (Next Month)

5. 📊 **Enhanced monitoring** (Tier 5 Phase 2)
   - Galera-specific Prometheus metrics
   - RocketChat alerts for cluster_size != expected
   - Dashboard for wsrep_* status variables

6. 📋 **Runbook validation** (Tier 5 Phase 3)
   - Practice bootstrap procedures monthly
   - Validate MANUAL_MODE workflow
   - Document lessons learned

### Long-Term Considerations (Next Quarter)

7. 🏗️ **Staging environment evaluation**
   - Cost-benefit analysis for dedicated 5-replica staging
   - Quota request if justified
   - Alternative: temporary scale-up in test (Tier 4 Option A)

8. 🔍 **Root cause deep dive**
   - Engage OpenShift Platform Services about SDN latency patterns
   - Review network policies for unnecessary hops
   - Consider multi-AZ placement impact on Galera replication

---

## Why NOT to Scale Dev to 5 Replicas @ 60m CPU

**The user asked about this approach — here's why it's counterproductive:**

| Aspect | 5 Replicas @ 60m CPU | Production (5 @ 100m) | Result |
|--------|---------------------|----------------------|--------|
| **Heartbeat latency** | HIGH (CPU starvation delays) | NORMAL (sufficient CPU) | ❌ False failures |
| **SST performance** | SLOW (compression bottleneck) | FAST (adequate CPU) | ❌ Different recovery time |
| **Failure mode** | CPU scheduling delays | Network packet loss | ❌ Testing wrong problem |
| **Representativeness** | Low (artificial problem) | N/A | ❌ Won't validate prod fix |
| **Resource efficiency** | Wasteful (5 starved pods) | N/A | ❌ Bad use of quota |

**Verdict**: ❌ Don't do it. Use chaos engineering (Tier 2) instead.

---

## Success Metrics

How to know if the strategy is working:

### Dev/Test Metrics (Chaos Testing)
- ✅ Cluster survives 100ms latency injection without split-brain
- ✅ Cluster survives 2% packet loss without NON-PRIMARY transitions
- ✅ Cluster recovers from 25s network partition (within new 30s timeout)
- ✅ Load test shows <1% transaction failure during pod restart

### Production Metrics (After Deployment)
- ✅ Zero split-brain events over 30 days (vs previous frequency)
- ✅ No "connection timeout" errors in Galera logs
- ✅ wsrep_cluster_size stable at 5 (99.9% uptime SLO)
- ✅ Graceful pod restarts complete without cluster disruption

### Operational Metrics
- ✅ MANUAL_MODE used successfully during incident response
- ✅ Mean time to recovery (MTTR) for split-brain reduced by 50%
- ✅ Runbook validated through practice (not learned during outage)

---

## Next Steps

**What to do right now:**

1. Review [config/mariadb/galera-timeouts.yaml](../config/mariadb/galera-timeouts.yaml)
2. Update [openshift/scripts/deploy-mariadb-galera.sh](../openshift/scripts/deploy-mariadb-galera.sh) with `--set extraFlags`
3. Deploy to dev, validate settings applied
4. Run single chaos test (network latency injection) to prove concept
5. If successful, promote to test → prod

**What NOT to do:**
- ❌ Scale dev to 5 replicas with 60m CPU (creates false failure mode)
- ❌ Deploy timeout changes directly to prod without dev/test validation
- ❌ Skip chaos testing (you'll miss configuration errors)
- ❌ Re-enable pod-health-monitor in prod without MANUAL_MODE testing

---

## Questions & Answers

**Q: Can we test split-brain in dev/test without 5 replicas?**
A: Yes — use chaos engineering (network latency/packet loss injection) to simulate the conditions that cause split-brain. You're testing network resilience, not replica count.

**Q: Is it safe to increase timeouts in production?**
A: Yes — the trade-off is acceptable:
  - Old: 15s detection, frequent false positives (split-brain)
  - New: 30s detection, eliminated false positives
  - True node failures take 15s longer to detect (acceptable for stability)

**Q: What if chaos testing shows problems?**
A: Adjust timeouts incrementally:
  - Start: PT30S (2× default)
  - If still fails: PT45S (3× default)
  - If passes: Try PT25S (1.67× default) to find minimum safe value

**Q: Should we keep pod-health-monitor disabled?**
A: No — re-enable it after:
  1. MANUAL_MODE workflow tested in dev
  2. Timeout configuration deployed across environments
  3. Runbooks updated with "enable MANUAL_MODE first" procedures

**Q: When do we know we're done?**
A: When production runs 30 days without split-brain events AND chaos testing in dev shows cluster survives realistic network failures. The goal is resilience, not perfection.
