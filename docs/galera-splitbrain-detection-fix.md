# Galera Split-Brain Detection Fix

## Issue Discovered

**Date**: 2026-04-13
**Severity**: Critical - False positive causing unnecessary cluster rebuilds

## Root Cause

The split-brain detection logic in `check_galera_cluster_health()` was triggering on **cluster_size mismatch** even when all pods shared the **same cluster UUID**.

### What Happened

```
mariadb-galera-0: uuid=0651454b-3737-11f1-8475-263c762cbe13, size=1, state=Synced
mariadb-galera-1: uuid=0651454b-3737-11f1-8475-263c762cbe13, size=4, state=Synced
mariadb-galera-2: uuid=0651454b-3737-11f1-8475-263c762cbe13, size=4, state=Synced
mariadb-galera-3: uuid=0651454b-3737-11f1-8475-263c762cbe13, size=4, state=Synced
mariadb-galera-4: uuid=0651454b-3737-11f1-8475-263c762cbe13, size=4, state=Synced
```

**Old Logic**: Detected "split-brain" because `unique_sizes = 2` (sizes: 1, 4)
**Reality**: This is a **temporary network partition**, NOT split-brain

All pods share UUID `0651454b-3737-11f1-8475-263c762cbe13` = they're part of the SAME cluster.

## What is TRUE Split-Brain?

**Definition**: Multiple independent Galera clusters with **different UUIDs** running simultaneously, each accepting writes independently. This creates **data divergence** (different datasets that cannot be automatically merged).

**Example of TRUE split-brain**:
```
Pod 0: uuid=aaaa-1111  size=2  (Pod 0 & 1 think they're a cluster)
Pod 1: uuid=aaaa-1111  size=2
Pod 2: uuid=bbbb-2222  size=3  (Pod 2, 3, 4 think they're a different cluster)
Pod 3: uuid=bbbb-2222  size=3
Pod 4: uuid=bbbb-2222  size=3
```

Both groups accept writes → **data divergence** → cannot auto-resolve → **requires human decision** on which dataset to keep.

## What is a Network Partition?

**Definition**: Temporary loss of connectivity between nodes in the SAME cluster (same UUID). Common causes:

- Pod restart (galera-0 briefly isolated during container startup)
- Rolling update (pods restart sequentially)
- Temporary network issues (switch failover, route changes)
- Node maintenance (pods migrated to different OpenShift nodes)

**Key characteristic**: All pods share the same UUID → they will **automatically rejoin** when connectivity is restored.

**Example**:
```
Pod 0: uuid=aaaa-1111  size=1  (isolated, sees only itself)
Pod 1: uuid=aaaa-1111  size=4  (quorum group)
Pod 2: uuid=aaaa-1111  size=4
Pod 3: uuid=aaaa-1111  size=4
Pod 4: uuid=aaaa-1111  size=4
```

**Outcome**: When Pod 0's network is restored:
1. Pod 0 detects it's isolated (size=1 < expected 5)
2. Pod 0 discovers the quorum group via DNS (mariadb-galera-headless)
3. Pod 0 automatically rejoins via IST (Incremental State Transfer)
4. All 5 pods report size=5 within seconds/minutes

**No intervention needed** - this is NORMAL Galera behavior.

## The Fix

### Before (WRONG)
```bash
if [[ $unique_uuids -gt 1 || $unique_sizes -gt 1 ]]; then
    send_notification "GALERA_SPLIT_BRAIN_DETECTED" ...
    return 2  # Triggered auto-heal on partitions!
fi
```

This caused **unnecessary cluster rebuilds** (scale to 0, delete PVCs, bootstrap from scratch) during:
- Rolling updates
- Pod restarts
- Temporary network issues

### After (CORRECT)
```bash
# TRUE SPLIT-BRAIN: Multiple cluster UUIDs (emergency)
if [[ $unique_uuids -gt 1 ]]; then
    send_notification "GALERA_SPLIT_BRAIN_DETECTED" ...
    return 2  # Only trigger on TRUE split-brain
fi

# NETWORK PARTITION: Same UUID, different sizes (self-healing)
if [[ $unique_sizes -gt 1 ]]; then
    # Check for quorum (majority of nodes agree on cluster size)
    if [[ quorum exists ]]; then
      echo "Quorum exists - isolated pods will rejoin automatically"
      return 0  # Healthy - no intervention needed
    else
      return 1  # Unhealthy - may need attention
    fi
fi
```

## Return Code Definitions

| Code | Meaning | Auto-Heal Action | Example |
|------|---------|------------------|---------|
| **0** | Healthy | None | All 5 pods synced, size=5, same UUID |
| **0** | Partition with quorum | None (self-healing) | 1 pod size=1, 4 pods size=4, same UUID |
| **1** | Unhealthy | Maybe (conservative) | Pods failing health checks, no quorum |
| **2** | TRUE split-brain | YES (emergency) | Different UUIDs detected |

## Impact

**Before**: Network partition during rolling update → full cluster rebuild (PVC deletion, 10+ min downtime)
**After**: Network partition → log message → auto-heals within seconds

**Before**: 30 attempted scale-ups, all resulted in "split-brain" false positives
**After**: Partitions tolerated, only TRUE split-brain triggers emergency rebuild

## Monitoring Recommendations

### What to Alert On
- ✅ **Different UUIDs** - immediate escalation (data loss risk)
- ⚠️ **Partition > 5 minutes** - investigate (may indicate persistent network issue)
- ℹ️ **Partition < 5 minutes** - log only (normal during operations)

### What NOT to Alert On
- ❌ **Cluster size mismatch** during rolling updates
- ❌ **Temporary partition** with quorum (4/5 pods agree)
- ❌ **Single pod isolated** (will rejoin automatically)

## Testing the Fix

```powershell
# Simulate partition by restarting galera-0
oc delete pod mariadb-galera-0 -n 950003-prod

# Monitor health checks (should NOT trigger split-brain alert)
oc logs deployment/pod-health-monitor -n 950003-prod -f

# Expected behavior:
# 1. Pod 0 reports size=1 (isolated)
# 2. Pods 1-4 report size=4 (quorum)
# 3. Health check returns 0 (healthy - quorum exists)
# 4. Pod 0 rejoins within 30-60s
# 5. All pods report size=5
```

## Related Changes

- **File**: `openshift/scripts/utils/database.sh`
- **Function**: `check_galera_cluster_health()`
- **Lines**: ~296-340 (split-brain detection logic)
- **Commit**: [Reference this PR/commit]

## References

- [Galera Cluster Documentation - Network Partitioning](https://galeracluster.com/library/documentation/split-brain.html)
- [MariaDB - Understanding wsrep_cluster_state_uuid](https://mariadb.com/kb/en/galera-cluster-status-variables/#wsrep_cluster_state_uuid)
- [Architecture: galera-monitoring-solution.md](./galera-monitoring-solution.md)
- [Troubleshooting: manual-galera-troubleshooting.md](./manual-galera-troubleshooting.md)
