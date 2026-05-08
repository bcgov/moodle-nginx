# Production Split-Brain Testing Strategy

## Executive Summary

This document outlines a safe, systematic approach to reproducing and resolving production Galera split-brain issues in the dev environment.

## 🎯 Testing Objectives

1. **Validate the hypothesis**: PT15S timeouts + resource pressure = split-brain
2. **Test bootstrap script**: Validate `bootstrap-mariadb-galera.ps1` works correctly
3. **Test timeout fix**: Confirm PT30S prevents split-brain under load
4. **Build confidence**: Deploy to prod with validated solution

## 🔬 Why Only Production is Affected

### Network Latency Theory (UNLIKELY)

If dev/test/prod all use OpenShift Silver with identical network policies:

```
❌ Network latency alone does NOT explain why only prod fails
```

**Evidence:**
- Same OpenShift cluster (Silver)
- Same network policies
- Same SDN overlay (OVN)

### Resource Contention Theory (LIKELY)

| Factor | Dev (2 nodes) | Prod (5 nodes) | Multiplier Effect |
|--------|---------------|----------------|-------------------|
| **Traffic** | ~10 users | ~1000 users | 100x load |
| **DB Connections** | ~20 concurrent | ~200 concurrent | 10x connections |
| **CPU Pressure** | 20% usage | 80-95% usage | 4-5x pressure |
| **Memory Pressure** | 40% usage | 85-90% usage | 2x pressure |
| **Galera Gossip** | 2 nodes = 1 link | 5 nodes = 10 links | 10x overhead |
| **Replication Lag** | <100ms | 500ms-2s | 5-20x lag |

**Combined Effect:**
```
Base latency (8s) + CPU pauses (3s) + Memory GC (2s) + Replication lag (2s) = 15s+
```

**In Production:**
- 95% CPU → Garbage collection pauses (2-5s)
- High memory → Swapping/OOM killer delays (1-3s)
- 200 connections → Network buffer exhaustion (1-2s)
- 5 nodes → Galera protocol overhead (1-2s)
- **Total delay: 15-17s → Exceeds PT15S → Split-brain!**

**In Dev:**
- 20% CPU → No GC pauses
- Low memory → No swapping
- 20 connections → No buffer issues
- 2 nodes → Minimal Galera overhead
- **Total delay: 8-10s → Within PT15S → No split-brain**

## 🧪 Safe Testing Plan

### Phase 1: Baseline Measurement (NO RISK)

**Objective:** Measure current network and resource characteristics

```powershell
# 1. Measure network latency
.\scripts\measure-galera-network-latency.ps1 -Namespace 950003-dev
.\scripts\measure-galera-network-latency.ps1 -Namespace 950003-prod

# 2. Check resource usage
oc adm top pods -n 950003-dev -l app.kubernetes.io/name=mariadb-galera
oc adm top pods -n 950003-prod -l app.kubernetes.io/name=mariadb-galera

# 3. Check current timeouts
oc exec mariadb-galera-0 -n 950003-dev -c mariadb-galera -- \
  mysql -umoodle -p"$MARIADB_PASSWORD" -sN -e \
  "SHOW VARIABLES LIKE 'wsrep_provider_options';" | grep inactive_timeout
```

**Expected Results:**
- Network latency similar in dev/prod (8-12s)
- Resource usage MUCH higher in prod (80-95% vs 20%)
- Current timeout: PT15S (both environments)

**Conclusion:** Resource contention, not network, is the issue

---

### Phase 2: Scale Up Dev to 3 Replicas (LOW RISK)

**Objective:** Better mimic production quorum behavior

#### 2.1: Right-Size Dev Resources

```yaml
# Current dev sizing (example):
resources:
  requests:
    cpu: 1000m
    memory: 2Gi
  limits:
    cpu: 2000m
    memory: 4Gi

# Proposed 3-replica sizing:
resources:
  requests:
    cpu: 500m      # 50% reduction
    memory: 1Gi    # 50% reduction
  limits:
    cpu: 1000m     # 50% reduction
    memory: 2Gi    # 50% reduction
```

**Math:**
- Current: 2 replicas × 2 CPU = 4 CPU total
- Proposed: 3 replicas × 1 CPU = 3 CPU total
- **Net savings: 25% CPU reduction**

#### 2.2: Deploy 3-Replica Configuration

```powershell
# Update StatefulSet replica count
oc scale statefulset mariadb-galera --replicas=3 -n 950003-dev

# Wait for mariadb-galera-2 to sync
oc wait --for=condition=ready pod/mariadb-galera-2 -n 950003-dev --timeout=300s

# Verify cluster
oc exec mariadb-galera-0 -n 950003-dev -c mariadb-galera -- \
  mysql -umoodle -p"$MARIADB_PASSWORD" -sN -e \
  "SHOW STATUS LIKE 'wsrep_cluster_size';"
# Expected: 3
```

**Benefits:**
- ✅ Better mimics prod (quorum = 2/3 = 67%)
- ✅ Can test rolling restart with quorum maintenance
- ✅ More realistic Galera gossip overhead

**Risks:**
- ⚠️ May hit namespace CPU/memory limits
- ⚠️ May need to request quota increase if fails

---

### Phase 3: Reproduce Split-Brain Safely (MODERATE RISK)

**Objective:** Trigger split-brain in dev to validate bootstrap script

#### Option A: Aggressive Timeout Reduction (RECOMMENDED)

```powershell
# Test with PT8S (very aggressive but not instant)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -CustomTimeout PT8S

# Monitor for split-brain (should occur within hours if resource pressure added)
oc logs -f -l app.kubernetes.io/name=mariadb-galera -n 950003-dev | grep -i "non-prim\|split"
```

**Why PT8S?**
- PT1S: Too extreme, instant chaos, hard to learn from
- PT8S: Aggressive enough to trigger with load, but measurable
- PT15S: Current default, may not trigger in low-load dev

**Expected Timeline:**
- Idle cluster: May never split (no resource pressure)
- Under load: Split-brain within 2-4 hours

#### Option B: Add Resource Pressure (ADVANCED)

Combine aggressive timeouts with synthetic load:

```bash
# Launch load tester (from pod-health-monitor or separate pod)
for i in {1..50}; do
  mysql -h mariadb-galera-primary -umoodle -p"$MARIADB_PASSWORD" \
    -e "SELECT COUNT(*) FROM mdl_user; SELECT SLEEP(2);" &
done

# Watch for split-brain
oc logs -f mariadb-galera-0 -n 950003-dev | grep -i "non-prim"
```

**Creates:**
- 50 concurrent connections
- CPU pressure from query execution
- Network buffer pressure
- Replication lag

#### Option C: CPU Throttling (SAFEST)

Reduce CPU limits to force resource contention:

```yaml
resources:
  limits:
    cpu: 200m  # Severe throttling
    memory: 1Gi
```

**Result:** Forces CPU throttling → GC pauses → timeout violations → split-brain

---

### Phase 4: Validate Bootstrap Script (CRITICAL)

**Objective:** Ensure `bootstrap-mariadb-galera.ps1` recovers cluster correctly

Once split-brain achieved in dev:

```powershell
# 1. Analyze current state (read-only, safe)
.\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-dev -Analyze

# Expected output:
#   Node: mariadb-galera-0
#     seqno: 42567
#     safe_to_bootstrap: 0
#   Node: mariadb-galera-1
#     seqno: 42567
#     safe_to_bootstrap: 0
#   Node: mariadb-galera-2
#     seqno: 42570  <- Highest
#     safe_to_bootstrap: 0
#
#   Recommended bootstrap node: mariadb-galera-2

# 2. Execute bootstrap (destructive, but dev data)
.\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-dev -Bootstrap

# 3. Verify recovery
oc exec mariadb-galera-0 -n 950003-dev -c mariadb-galera -- \
  mysql -umoodle -p"$MARIADB_PASSWORD" -sN -e \
  "SHOW STATUS LIKE 'wsrep_cluster_%';"

# Expected:
#   wsrep_cluster_status: Primary
#   wsrep_cluster_size: 3
```

**Validation Checklist:**
- ✅ Script correctly identifies highest seqno node
- ✅ Bootstrap process completes without errors
- ✅ All 3 nodes rejoin cluster
- ✅ Cluster status = Primary
- ✅ No data loss (verify row counts)

---

### Phase 5: Deploy Timeout Fix (LOW RISK)

**Objective:** Confirm PT30S prevents split-brain under same conditions

```powershell
# Deploy timeout fix
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Dev

# Re-apply load testing (same as Phase 3)
# Monitor for 24-48 hours
# Expected: NO split-brain even under load
```

**Success Criteria:**
- ✅ No split-brain events for 48 hours
- ✅ Cluster remains stable under load
- ✅ Resource usage similar to Phase 3 (proves timeout fix, not reduced load)

---

### Phase 6: Production Deployment (PLANNED)

**Objective:** Deploy validated solution to production

```powershell
# 1. Deploy to test environment first (if available)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-test -Profile Test -WhatIf
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-test -Profile Test

# 2. Monitor test for 24-48 hours

# 3. Deploy to production (change window)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod -WhatIf
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod

# 4. Monitor production for 7 days
oc logs -f -l app.kubernetes.io/name=mariadb-galera -n 950003-prod | grep -i "non-prim\|split"
```

**Rollback Plan:**
```powershell
# If split-brain persists (unlikely):
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Full

# If cluster is down:
.\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-prod -Bootstrap
```

---

## 📊 Test Scenarios Matrix

| Scenario | Replicas | Timeout | Load | Resource Limits | Expected Result | Purpose |
|----------|----------|---------|------|-----------------|-----------------|---------|
| **Baseline** | 2 | PT15S | None | Normal | No split-brain | Current state |
| **Scale Up** | 3 | PT15S | None | Normal | No split-brain | Mimic prod quorum |
| **Aggressive Timeout** | 3 | PT8S | None | Normal | Split-brain likely | Trigger failure |
| **With Load** | 3 | PT8S | Synthetic | Normal | Split-brain certain | Reproduce prod |
| **CPU Throttle** | 3 | PT8S | None | cpu=200m | Split-brain certain | Force resource contention |
| **Fixed Timeout** | 3 | PT20S | Same load | Normal | No split-brain | Validate fix |
| **Production** | 5 | PT30S | Real traffic | Normal | No split-brain | Final deployment |

---

## 🚨 Risk Assessment

### Dev Environment Risks

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Data loss during split-brain | Medium | Low | Dev data is non-critical |
| Bootstrap script fails | Low | Medium | Have backups, can restore PVCs |
| Dev unavailable for 1-2 hours | High | Low | Schedule during off-hours |
| Corrupt PVC requiring rebuild | Low | Medium | Document PVC backup/restore process |
| CPU limit prevents scale to 3 | Medium | Low | Request quota increase or reduce per-pod resources |

### Production Risks (After Testing)

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Timeout fix doesn't work | Very Low | Critical | Tested in dev/test first |
| Bootstrap needed in prod | Low | High | Validated script in dev |
| Rolling restart causes brief outage | High | Medium | Each pod 30-60s read-only, UI shows maintenance |
| Unknown issue during deployment | Very Low | Critical | Deploy during maintenance window, have rollback ready |

---

## 📝 Testing Checklist

### Pre-Testing
- [ ] Backup dev PVCs (optional, for peace of mind)
- [ ] Document current dev state (pod count, resource usage, data)
- [ ] Schedule testing window (off-hours, low traffic)
- [ ] Notify team of planned dev downtime

### Phase 1: Baseline (30 minutes)
- [ ] Run network latency measurement in dev
- [ ] Run network latency measurement in prod
- [ ] Compare results (should be similar)
- [ ] Record resource usage (should differ significantly)

### Phase 2: Scale to 3 Replicas (2 hours)
- [ ] Right-size dev resources (reduce CPU/memory per pod)
- [ ] Scale to 3 replicas
- [ ] Verify all 3 nodes synced
- [ ] Run basic health checks
- [ ] Monitor for 1 hour (ensure stable)

### Phase 3: Reproduce Split-Brain (4-24 hours)
- [ ] Deploy PT8S aggressive timeout
- [ ] Apply synthetic load (optional)
- [ ] Monitor logs for NON-PRIMARY status
- [ ] Wait for split-brain event
- [ ] Document exact error messages and timing

### Phase 4: Validate Bootstrap (1-2 hours)
- [ ] Run `-Analyze` mode
- [ ] Verify highest seqno detection is correct
- [ ] Execute `-Bootstrap` mode
- [ ] Confirm cluster recovery (all nodes Primary)
- [ ] Verify no data loss (check row counts)
- [ ] Document any issues or improvements needed

### Phase 5: Deploy Fix (2-4 hours)
- [ ] Deploy PT20S (Dev profile)
- [ ] Re-apply same synthetic load
- [ ] Monitor for 24-48 hours
- [ ] Confirm NO split-brain events
- [ ] Success!

### Phase 6: Production (4 hours + monitoring)
- [ ] Schedule maintenance window
- [ ] Deploy to test environment (if available)
- [ ] Deploy to production (during window)
- [ ] Monitor for 7 days
- [ ] Document final results

---

## 🎓 Learning Outcomes

After completing this testing:

1. **Root Cause Confirmed**: Resource contention (not network) causes split-brain
2. **Bootstrap Script Validated**: Safe cluster recovery process verified
3. **Timeout Fix Proven**: PT30S prevents split-brain under load
4. **Confidence Built**: Team has tested recovery procedures
5. **Production Ready**: Deploy with confidence

---

## 📞 Escalation Plan

If testing reveals unexpected issues:

1. **Bootstrap script doesn't work**:
   - Document failure mode
   - Manually recover using [manual-galera-troubleshooting.md](manual-galera-troubleshooting.md)
   - Enhance script based on learnings

2. **Timeout fix doesn't prevent split-brain**:
   - Try more aggressive timeout (PT40S, PT60S)
   - Investigate other Galera parameters (flow control, etc.)
   - Consider application-level connection pooling improvements

3. **Dev CPU quota insufficient for 3 replicas**:
   - Request quota increase from platform team
   - OR test with 2 replicas + aggressive CPU limits
   - OR test in test environment (should have more quota)

4. **Production deployment fails**:
   - Rollback to Default profile (PT15S)
   - Use bootstrap script to recover cluster
   - Investigate prod-specific factors

---

## 🔗 Related Documentation

- [Galera Timeout Tuning Strategy](galera-timeout-tuning-strategy.md) - Comprehensive timeout explanation
- [Manual Galera Troubleshooting](manual-galera-troubleshooting.md) - Manual recovery procedures
- [Bootstrap MariaDB Galera Script](../scripts/bootstrap-mariadb-galera.ps1) - Automated recovery tool

---

**Last Updated:** 2026-04-12
**Next Review:** After Phase 5 completion
**Owner:** DevOps Team
