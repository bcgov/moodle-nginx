# Galera Timeout Tuning Strategy

## Quick Reference

| Environment | Replicas | Network Profile | Recommended Profile | Timeout |
|-------------|----------|-----------------|---------------------|---------|
| **Dev** | 2 | Low-latency | `Dev` or `Default` | PT20S or PT15S |
| **Test** | 3 | Medium-latency | `Test` | PT25S |
| **Prod** | 5 | High-latency (SDN) | `Prod` or `Full` | PT30S |

## Timeout Tradeoffs

### Tight Timeouts (PT15S - Bitnami Default)

**Advantages:**
- ✅ Fast failure detection (15 seconds)
- ✅ Quick recovery from actual node failures
- ✅ Lower read-only window during failover

**Disadvantages:**
- ❌ False positives in high-latency networks
- ❌ Triggers split-brain from transient network issues
- ❌ OpenShift SDN network policies can exceed 15s
- ❌ Production outages from non-critical network hiccups

**Best For:**
- Low-latency bare-metal clusters
- Direct network connections (no SDN/overlay)
- Development environments where outages are acceptable

### Relaxed Timeouts (PT30S - Recommended for OpenShift)

**Advantages:**
- ✅ Tolerates transient network latency
- ✅ Prevents false split-brain in SDN environments
- ✅ Stable production operations
- ✅ Handles OpenShift network policy overhead

**Disadvantages:**
- ❌ Slower detection of actual failures (30 seconds vs 15)
- ❌ Longer read-only window during real failover
- ❌ May mask underlying network issues

**Best For:**
- Production OpenShift clusters
- Environments with network policies
- SDN/overlay networks (Calico, OVN, etc.)
- High-availability requirements

## When to Use Each Profile

### `Default` - Restore Original Bitnami Defaults (PT15S)

```powershell
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Default
```

**Use When:**
- ✅ Restoring after testing prod settings in dev
- ✅ Dev/test environments never had split-brain issues
- ✅ Low-latency network confirmed via testing
- ✅ Cluster is behind load balancer with fast detection

**⚠️ WARNING:** PT15S may cause split-brain in OpenShift SDN environments

### `Dev` - Optimized for 2-Replica Dev (PT20S)

```powershell
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Dev
```

**Use When:**
- ✅ 2-node dev cluster
- ✅ Balancing fast detection with SDN tolerance
- ✅ Testing timeout changes before prod deployment

**Settings:**
- `evs.inactive_timeout=PT20S`
- `evs.suspect_timeout=PT8S`

### `Test` - Moderate for 3-Replica Test (PT25S)

```powershell
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-test -Profile Test
```

**Use When:**
- ✅ 3-node test cluster
- ✅ Staging environment for prod changes
- ✅ Medium network latency

**Settings:**
- `evs.inactive_timeout=PT25S`
- `evs.suspect_timeout=PT10S`

### `Prod` - Aggressive for 5-Replica Production (PT30S)

```powershell
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod
```

**Use When:**
- ✅ 5-node production cluster
- ✅ Recurring split-brain issues
- ✅ OpenShift SDN environment
- ✅ High-availability requirements

**Settings:**
- `evs.inactive_timeout=PT30S`
- `evs.suspect_timeout=PT10S`
- `gcs.fc_limit=256` (flow control for large clusters)

### `Full` - All Recommended Settings (Production-Ready)

```powershell
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Full
```

**Use When:**
- ✅ Comprehensive timeout tuning needed
- ✅ All 7 parameters require optimization
- ✅ Maximum stability desired

**Settings:**
- All Tier 1, Tier 2, and Tier 3 parameters
- See [config/mariadb/galera-timeouts.yaml](../config/mariadb/galera-timeouts.yaml)

### `Minimal` - Conservative Change (PT30S Only)

```powershell
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Minimal
```

**Use When:**
- ✅ Want smallest possible change
- ✅ Testing timeout impact incrementally
- ✅ Cautious approach to production changes

**Settings:**
- `evs.inactive_timeout=PT30S` only

## Common Scenarios

### Scenario 1: Production Experiencing Split-Brain

**Problem:** Production (5-node cluster) has recurring split-brain events

**Solution:**
```powershell
# Emergency fix - deploy to production
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod

# Or use comprehensive settings
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Full
```

**Why:** PT30S tolerates OpenShift SDN latency that was causing false split-brain

### Scenario 2: Testing Prod Fix in Dev First

**Problem:** Want to test prod timeout settings in dev before deploying to prod

**Workflow:**
```powershell
# Step 1: Test prod settings in dev
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Full -WhatIf
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Full

# Step 2: Monitor for 24-48 hours

# Step 3: Deploy to prod
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod

# Step 4: Restore dev to dev-optimized settings
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Dev
```

**Why:** Dev can safely run prod settings temporarily, then restore to faster detection

### Scenario 3: Only Prod Has Issues, Dev/Test Are Fine

**Problem:** Prod has split-brain, but dev/test never had issues

**Solution:**
```powershell
# Dev: Keep tight timeouts (never had issues)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-dev -Profile Default

# Test: Moderate timeouts (preventive)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-test -Profile Test

# Prod: Increase to PT30S (fix split-brain)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod
```

**Why:** Each environment has different network characteristics; tune accordingly

### Scenario 4: Incremental Tuning

**Problem:** Want to find minimum timeout that prevents split-brain

**Workflow:**
```powershell
# Start with minimal change
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Minimal

# Monitor for 48 hours
# If issues persist, try Dev profile (PT20S)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Dev

# If issues persist, try Test profile (PT25S)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Test

# Finally, try Prod profile (PT30S)
.\scripts\deploy-galera-timeouts.ps1 -Namespace 950003-prod -Profile Prod
```

**Why:** Find sweet spot between fast detection and false positives

## Network Latency Analysis

### How to Measure Your Network Latency

```bash
# From pod-health-monitor, test latency between Galera pods
oc exec deployment/pod-health-monitor -n 950003-prod -- bash -c '
  for pod in mariadb-galera-0 mariadb-galera-1 mariadb-galera-2; do
    echo "Testing $pod..."
    time nc -zv $pod.mariadb-galera-headless 4567
  done
'

# Check for network policy delays
oc exec mariadb-galera-0 -n 950003-prod -- time mysql -h mariadb-galera-1.mariadb-galera-headless -umoodle -p$MARIADB_PASSWORD -e "SELECT 1"
```

**Interpretation:**
- **<5s**: Default (PT15S) likely safe
- **5-10s**: Dev (PT20S) recommended
- **10-15s**: Test (PT25S) recommended
- **>15s**: Prod (PT30S) required

### Why OpenShift Adds Latency

1. **SDN Overlay Network**: Packets traverse overlay (OVN/Calico)
2. **Network Policies**: Evaluated on every connection
3. **Pod/Service Mesh**: Additional hops through kube-proxy
4. **Node Scheduling**: Pods may be on different nodes/racks

## Verification

After deploying timeout configuration:

```powershell
# Check applied configuration
oc exec mariadb-galera-0 -n 950003-prod -c mariadb-galera -- \
  mysql -umoodle -p"$MARIADB_PASSWORD" -sN -e \
  "SHOW VARIABLES LIKE 'wsrep_provider_options';" | grep inactive_timeout

# Expected output examples:
# Default:  evs.inactive_timeout = PT15S
# Dev:      evs.inactive_timeout = PT20S
# Test:     evs.inactive_timeout = PT25S
# Prod:     evs.inactive_timeout = PT30S
```

## Related Documentation

- [Galera Timeout Reference](../config/mariadb/galera-timeouts.yaml) - Detailed parameter explanations
- [Manual Galera Troubleshooting](manual-galera-troubleshooting.md) - Recovery procedures
- [Galera Monitoring Solution](galera-monitoring-solution.md) - Automated health checks

## Scripts

| Script | Purpose | Documentation |
|--------|---------|---------------|
| [deploy-galera-timeouts.ps1](../scripts/deploy-galera-timeouts.ps1) | Deploy timeout configuration | This document |
| [bootstrap-mariadb-galera.ps1](../scripts/bootstrap-mariadb-galera.ps1) | Recover from split-brain | [Manual Troubleshooting](manual-galera-troubleshooting.md) |
| [galera-inspect.sh](../openshift/scripts/galera-inspect.sh) | Diagnostic analysis | [Monitoring Solution](galera-monitoring-solution.md) |

---

**Last Updated:** 2026-04-12
**Maintained By:** DevOps Team
