# Galera Timeout Configuration Reference

> **STATUS:** Reference documentation only - not used by automation  
> **Current Approach:** Timeouts are baked into environment-specific my.cnf files

## Overview

This document provides reference information about Galera timeout parameters for split-brain prevention in OpenShift environments.

**Current Implementation:**
- Development: [config/mariadb/950003-dev.cnf](../config/mariadb/950003-dev.cnf) (PT20S)
- Test: [config/mariadb/950003-test.cnf](../config/mariadb/950003-test.cnf) (PT25S)
- Production: [config/mariadb/950003-prod.cnf](../config/mariadb/950003-prod.cnf) (PT30S)

## Background

Galera defaults (`evs.inactive_timeout=PT15S`) are optimized for bare-metal deployments with low-latency, dedicated networks. OpenShift introduces additional latency sources:

- **SDN overlay network** (OVN-Kubernetes)
- **Service mesh routing**
- **Node resource contention**
- **Cross-AZ network jitter** (multi-zone deployments)

### Root Cause Analysis

Production split-brain events showed "connection timeout" messages at 15-second intervals. 5-node clusters have 10 network paths that can experience transient failures. Default timeouts are too aggressive for cloud-native environments, causing false-positive node evictions.

### Solution

Increase timeouts to tolerate transient network issues without sacrificing actual failure detection. Values tuned for:
- 5-replica production cluster
- OpenShift Silver platform (multi-tenant, shared network)
- Acceptable trade-off: slower true-failure detection for elimination of false-positive split-brains

---

## Tier 1: Critical Split-Brain Prevention

### evs.inactive_timeout

**Purpose:** Time before a node is considered inactive and evicted from cluster

| Environment | Value | Rationale |
|------------|-------|-----------|
| **Bitnami Default** | PT15S | Too aggressive for OpenShift |
| **Development** | PT20S | Faster failover for 2-replica testing |
| **Test** | PT25S | Middle ground for 3-replica |
| **Production** | PT30S | Tolerates transient SDN latency |

**Impact:** Doubles tolerance for network hiccups before declaring node dead  
**Trade-off:** True node failures take 30s to detect instead of 15s

### evs.suspect_timeout

**Purpose:** Time before a node is marked "suspect" (pre-eviction warning state)

| Value | Description |
|-------|-------------|
| **Default** | PT5S | Too aggressive |
| **Development** | PT6.67S | Proportional to 20s inactive |
| **Test** | PT8.33S | Proportional to 25s inactive |
| **Production** | PT10S | Gives network time to recover |

**Impact:** Node marked suspect after 10s, evicted after 30s (20s grace period)  
**Trade-off:** Slightly slower failure detection, much fewer false positives

### evs.inactive_check_period

**Purpose:** How often to check for inactive nodes (heartbeat interval)

| Value | Impact |
|-------|--------|
| **Default** | PT0.5S (500ms) | High frequency |
| **All Environments** | PT1S (1000ms) | Reduces network chatter |

**Impact:** 50% fewer heartbeat packets (matters at scale)  
**Trade-off:** Detection granularity reduced from 0.5s to 1s (negligible)

---

## Tier 2: Network Stability

### evs.keepalive_period

**Purpose:** Keepalive message interval to detect silent network partitions

| Value | Impact |
|-------|--------|
| **Default** | PT1S | Frequent checks |
| **Production** | PT2S | Reduces overhead, still detects failures |

**Impact:** Fewer keepalive packets, lower network load  
**Trade-off:** Silent partition detection takes up to 2s longer

### evs.join_retrans_period

**Purpose:** Retransmit interval for join messages (when node tries to join cluster)

| Value | Impact |
|-------|--------|
| **Default** | PT1S | Aggressive retries |
| **Production** | PT2S | Less aggressive during SST |

**Impact:** Reduces log spam and network congestion during node startup  
**Trade-off:** Slower cluster join (acceptable — only affects startup/recovery)

---

## Tier 3: Flow Control

### gcs.fc_limit

**Purpose:** Flow control trigger — max replication events in queue before throttling

| Value | Impact |
|-------|--------|
| **Default** | 128 | Standard tolerance |
| **Production** | 256 | Higher tolerance for bursty workloads |

**Impact:** Allows more in-flight replication events before applying backpressure  
**Trade-off:** Uses more memory, prevents flow control pauses under load

### gcs.fc_factor

**Purpose:** Flow control resume threshold (as fraction of gcs.fc_limit)

| Value | Behavior |
|-------|----------|
| **Default** | 0.5 (resume at 64/128) | 50% hysteresis |
| **Production** | 0.5 (resume at 128/256) | Unchanged ratio |

**Impact:** Maintains 50% hysteresis to prevent flow control flapping

---

## Combined Configuration Strings

### Development (2 replicas, PT20S)

```ini
wsrep_provider_options="evs.inactive_timeout=PT20S;evs.suspect_timeout=PT6.67S;evs.inactive_check_period=PT6.67S;evs.install_timeout=PT20S;evs.consensus_timeout=PT20S"
```

### Test (3 replicas, PT25S)

```ini
wsrep_provider_options="evs.inactive_timeout=PT25S;evs.suspect_timeout=PT8.33S;evs.inactive_check_period=PT8.33S;evs.install_timeout=PT25S;evs.consensus_timeout=PT25S"
```

### Production (5+ replicas, PT30S)

```ini
wsrep_provider_options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT10S;evs.install_timeout=PT30S;evs.consensus_timeout=PT30S"
```

### Full Production (all tuning parameters)

```ini
wsrep_provider_options="evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;evs.inactive_check_period=PT1S;evs.keepalive_period=PT2S;evs.join_retrans_period=PT2S;gcs.fc_limit=256;gcs.fc_factor=0.5"
```

---

## Deployment Method (Current)

**Atomic my.cnf Upload via ConfigMap:**

```powershell
# Upload environment-specific my.cnf with baked-in timeouts
.\scripts\update-right-sizing.ps1 -Namespace 950003-prod

# Auto-detects: config/mariadb/950003-prod.cnf
# Uploads to: ConfigMap mariadb-galera-configuration
# Restarts: MariaDB pods to pick up new configuration
```

**Alternative: Manual ConfigMap Update:**

```bash
# Edit environment-specific file
vim config/mariadb/950003-prod.cnf

# Update ConfigMap
oc create configmap mariadb-galera-configuration \
  --from-file=my.cnf=config/mariadb/950003-prod.cnf \
  -n 950003-prod --dry-run=client -o yaml | oc apply -f -

# Restart pods
oc rollout restart statefulset/mariadb-galera -n 950003-prod
```

---

## Validation

**Check applied values:**

```bash
oc exec mariadb-galera-0 -n 950003-prod -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW VARIABLES LIKE 'wsrep_provider_options';"
```

**Search for specific setting:**

```bash
oc exec mariadb-galera-0 -n 950003-prod -- \
  mysql -uroot -p"$DB_ROOT_PASSWORD" \
  -e "SHOW VARIABLES LIKE 'wsrep_provider_options';" | grep inactive_timeout
```

**Expected output:**

```
wsrep_provider_options	...evs.inactive_timeout=PT30S...
```

---

## Monitoring Post-Deployment

Watch for these improved behaviors:
- ✅ Fewer "NON-PRIMARY" view transitions
- ✅ No "connection timeout" errors in logs
- ✅ Cluster remains stable during network hiccups
- ✅ SST operations complete successfully even under load

---

## References

- [Galera Parameters Documentation](https://galeracluster.com/library/documentation/galera-parameters.html)
- [MariaDB Galera System Variables](https://mariadb.com/kb/en/galera-cluster-system-variables/)
- [Right-Sizing + Galera Integration](right-sizing-galera-integration.md)
- [Production Split-Brain Resolution](PRODUCTION-SPLIT-BRAIN-RESOLUTION.md)
