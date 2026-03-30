# Database Clustering for High Availability: A Deep Dive

A reference guide for understanding database clustering, grounded in the Moodle-nginx project's infrastructure — from the current MariaDB Galera cluster to the upcoming CrunchyDB PostgreSQL deployment.

---

## Table of Contents

1. [Why Cluster a Database?](#1-why-cluster-a-database)
2. [The Fundamental Tradeoff: CAP Theorem](#2-the-fundamental-tradeoff-cap-theorem)
3. [Replication Models](#3-replication-models)
4. [Our Current Setup: MariaDB Galera (Synchronous Multi-Master)](#4-our-current-setup-mariadb-galera-synchronous-multi-master)
5. [Our Future Setup: CrunchyDB PostgreSQL (Primary-Replica with Patroni)](#5-our-future-setup-crunchydb-postgresql-primary-replica-with-patroni)
6. [Connection Pooling](#6-connection-pooling)
7. [Backup Strategies in Clustered Environments](#7-backup-strategies-in-clustered-environments)
8. [Failover: What Happens When a Node Dies](#8-failover-what-happens-when-a-node-dies)
9. [Split-Brain: The Nightmare Scenario](#9-split-brain-the-nightmare-scenario)
10. [Kubernetes and Databases](#10-kubernetes-and-databases)
11. [Why the Migration Makes Sense](#11-why-the-migration-makes-sense)
12. [Glossary](#12-glossary)

---

## 1. Why Cluster a Database?

With a single database server, you have two problems:

**Availability** — if that server crashes, your entire application goes down. There's no backup ready to take over. Your users see errors until you manually restore service.

**Scalability** — a single server has finite CPU, memory, and I/O. When you hit its ceiling, the only option is buying a bigger server ("vertical scaling"), which gets expensive fast and has hard limits.

Clustering addresses both by running multiple database servers that coordinate with each other:

```
Single Server:                    Clustered:

┌─────────────┐                   ┌─────────────┐
│  App Server  │                   │  App Server  │
└──────┬──────┘                   └──────┬──────┘
       │                                 │
       ▼                          ┌──────┼──────┐
┌─────────────┐                   ▼      ▼      ▼
│  Database   │             ┌────────┐┌────────┐┌────────┐
│  (single)   │             │ Node 0 ││ Node 1 ││ Node 2 │
└─────────────┘             └────────┘└────────┘└────────┘
                                  ▲      ▲      ▲
  If this dies,                   └──────┼──────┘
  everything dies.                    Synced
                              If one dies, others continue.
```

**But there's a catch.** The moment you have more than one copy of your data, you introduce the hardest problem in distributed systems: keeping those copies consistent.

---

## 2. The Fundamental Tradeoff: CAP Theorem

The CAP theorem (Brewer, 2000) states that a distributed system can only guarantee two of three properties simultaneously:

- **Consistency** — every read gets the most recent write
- **Availability** — every request gets a response (not an error)
- **Partition tolerance** — the system works even when network links between nodes fail

Since network partitions *will* happen in any real system (a cable gets unplugged, a switch reboots, a pod gets rescheduled), you always need partition tolerance. That leaves you choosing between:

| Choice | What you get | What you sacrifice | Example |
|--------|-------------|-------------------|---------|
| **CP** (Consistency + Partition tolerance) | Every read is accurate | Some requests may fail during partitions | Galera with `wsrep_causal_reads=ON` |
| **AP** (Availability + Partition tolerance) | System always responds | Reads might be stale | Async MySQL replicas |

In practice, systems sit on a spectrum. Our Galera cluster leans CP (it blocks writes during network issues rather than risk inconsistency). Our future CrunchyDB setup will also lean CP, but through a different mechanism (Patroni leader election).

### Why This Matters to You

When someone says "our database is highly available," ask: **available for reads, writes, or both? And what happens to consistency during a failure?** The answer is always a tradeoff.

---

## 3. Replication Models

There are three fundamental approaches to keeping data in sync across nodes.

### 3a. Synchronous Replication (Our Current Galera Approach)

Every write must be acknowledged by all nodes before the client gets a success response.

```
Timeline:
  Client sends INSERT ──► Node 0 receives
                           │
                           ├──► Sends write-set to Node 1 ──► Node 1 validates ──► OK
                           ├──► Sends write-set to Node 2 ──► Node 2 validates ──► OK
                           ├──► Sends write-set to Node 3 ──► Node 3 validates ──► OK
                           ├──► Sends write-set to Node 4 ──► Node 4 validates ──► OK
                           │
                           ▼
                    All confirmed → Commit on ALL nodes
                           │
                           ▼
                    Client gets "OK"
```

**Pros:**
- Strong consistency — no stale reads from any node
- Multi-master — any node can accept writes
- No data loss on node failure (all nodes have the same data)

**Cons:**
- Write latency increases with each node added (everyone must agree)
- Throughput ceiling — the slowest node limits everyone
- Complex recovery when the whole cluster goes down (bootstrap problem)

**In our `config/mariadb/my.cnf`:**
```ini
[galera]
wsrep_on=ON                     # Enable synchronous replication
wsrep_sst_method=mariabackup    # How new/recovering nodes get a full data copy
wsrep_slave_threads=4           # Parallel apply threads for incoming write-sets
```

### 3b. Asynchronous Replication (Traditional Primary-Replica)

The primary commits writes immediately, then ships the changes to replicas in the background. Replicas apply changes when they can.

```
Timeline:
  Client sends INSERT ──► Primary receives
                           │
                           ▼
                    Primary commits locally
                           │
                           ▼
                    Client gets "OK"         ◄── Client doesn't wait for replicas
                           │
                    (background)
                           │
                           ├──► Ships WAL/binlog to Replica 1 ──► applies (maybe 50ms later)
                           └──► Ships WAL/binlog to Replica 2 ──► applies (maybe 50ms later)
```

**Pros:**
- Fast writes — client doesn't wait for replicas
- Simple to set up
- Adding replicas doesn't slow down writes

**Cons:**
- **Replication lag** — replicas might be seconds (or minutes) behind
- If the primary crashes before shipping a change, that change is **lost**
- Reading from a replica might give stale data

### 3c. Semi-Synchronous Replication (Our Future CrunchyDB Approach)

A middle ground: the primary waits for **at least one** replica to confirm receipt before responding to the client, but doesn't wait for all of them.

```
Timeline:
  Client sends INSERT ──► Primary receives
                           │
                           ▼
                    Primary commits locally
                           │
                           ├──► Ships WAL to Replica 1 ──► Replica 1: "received" ──► OK
                           │
                           ▼
                    At least 1 replica confirmed
                           │
                           ▼
                    Client gets "OK"
```

CrunchyDB (via Patroni) uses PostgreSQL's **streaming replication** with configurable synchronous commit. The default is async, but it can be configured to require one or more replicas to confirm.

**Pros:**
- Faster than full synchronous (only wait for 1 replica, not all)
- Minimal data loss risk (at least 1 replica has every committed transaction)
- Simpler failover than multi-master

**Cons:**
- Only one node accepts writes (the primary)
- Still slightly slower than pure async

---

## 4. Our Current Setup: MariaDB Galera (Synchronous Multi-Master)

### Architecture

```
                        ┌─────────────────────┐
                        │  Kubernetes Service  │
                        │  "mariadb-galera"    │
                        │  (load balancer)     │
                        └──────────┬──────────┘
                                   │
              ┌────────────────────┼────────────────────┐
              │                    │                     │
              ▼                    ▼                     ▼          ···
        ┌───────────┐       ┌───────────┐        ┌───────────┐
        │  galera-0  │◄────►│  galera-1  │◄──────►│  galera-2  │     (up to 5 nodes)
        │  (R/W)     │      │  (R/W)     │        │  (R/W)     │
        └───────────┘       └───────────┘        └───────────┘
              │                    │                     │
        ┌───────────┐       ┌───────────┐        ┌───────────┐
        │  PVC 10Gi  │       │  PVC 10Gi  │        │  PVC 10Gi  │
        └───────────┘       └───────────┘        └───────────┘
```

Every node is identical. The Kubernetes `mariadb-galera` Service load-balances connections across all pods. Moodle doesn't know or care which node it's talking to — they all accept reads and writes.

### How Galera Replication Works (The Write-Set)

Galera doesn't replicate individual SQL statements. It replicates **write-sets** — the actual row-level changes produced by a transaction. Here's the detailed flow:

1. **Transaction executes locally** — the originating node runs the SQL and generates a write-set (a collection of row changes)
2. **Certification** — the write-set is broadcast to all nodes. Each node checks: "Does this write-set conflict with any transaction I'm currently processing?" This is a deterministic test based on primary key ranges.
3. **If certified** — all nodes apply the write-set and commit. The order is guaranteed globally.
4. **If conflict detected** — the transaction is rolled back on the originating node. The client gets an error (deadlock/conflict).

This is why our `my.cnf` has:

```ini
binlog_format=row            # REQUIRED: Galera needs row-level changes, not SQL statements
innodb_autoinc_lock_mode=2   # REQUIRED: "interleaved" mode allows concurrent inserts
```

**Why `binlog_format=row` is required:** Statement-based replication logs the SQL statement (`INSERT INTO users VALUES ('alice')`). But the same statement might produce different results on different nodes (think `NOW()`, `RAND()`, or trigger-dependent logic). Row-based replication logs the actual data change: "row with PK=42 was inserted with these column values." Deterministic, no ambiguity.

**Why `innodb_autoinc_lock_mode=2` is required:** In single-server mode (mode 1), InnoDB locks the auto-increment counter for the entire duration of an INSERT statement, guaranteeing consecutive IDs. In Galera, multiple nodes are generating IDs simultaneously — if they both locked and waited, you'd get deadlocks. Mode 2 (interleaved) assigns IDs without holding a table-level lock. The tradeoff: IDs may have gaps and won't be strictly sequential. This is fine for Moodle; IDs are opaque identifiers, not meaningful sequences.

### State Snapshot Transfer (SST) and Incremental State Transfer (IST)

When a node joins (or rejoins) the cluster, it needs to get caught up. Two mechanisms:

**SST (State Snapshot Transfer)** — a full copy of the entire database. Used when:
- A node is joining for the first time
- A node was offline so long that the Galera cache (gcache) no longer has its missing transactions

Our setup uses `mariabackup` for SST (`wsrep_sst_method=mariabackup`), which takes a hot backup of the donor node without locking it. Other SST methods include `rsync` (faster but locks the donor) and `mysqldump` (slow, locks the donor).

**IST (Incremental State Transfer)** — just the missing transactions from the gcache. Used when a node was only briefly offline and the gcache still has everything it missed. Much faster than SST.

```
Node 2 comes back online after 5 minutes:

  Node 0 checks gcache: "Node 2 last had transaction #4500, we're at #4520"
  gcache has transactions #4501-#4520?
    YES → IST: send just those 20 transactions
    NO  → SST: send full database copy via mariabackup
```

### Flow Control

What happens when one node is slower than the others? Galera uses **flow control**: if a node's apply queue (replication backlog) grows too large, it tells the other nodes to slow down. This prevents any single node from falling hopelessly behind, but it means the cluster's write throughput is limited by the slowest node.

Our `wsrep_slave_threads=4` setting helps by applying incoming write-sets in parallel across 4 threads rather than sequentially.

### The Bootstrap Problem

This is Galera's biggest operational headache. When the entire cluster is down (all nodes offline), you can't just start them all — they'd each try to form a new single-node cluster. You need to:

1. **Find the most up-to-date node** — the one with the highest sequence number (`seqno`) in its `grastate.dat` file
2. **Bootstrap from that node** — start it with `--wsrep-new-cluster` (or set `safe_to_bootstrap: 1`)
3. **Start the remaining nodes** — they'll join the bootstrapped node and get caught up via IST/SST

Our deploy script handles this:
```bash
--set galera.bootstrap.forceSafeToBootstrap=true
--set galera.bootstrap.forceBootstrap=true
--set galera.bootstrap.bootstrapFromNode=0
```

If you bootstrap from the *wrong* node (one that's behind), you lose any transactions that the more up-to-date nodes had. This is why our deploy script keeps the PVC for node 0 (`data-mariadb-galera-0`) and deletes the others — it always bootstraps from node 0.

### Graceful Shutdown: The PreStop Hook

Our `mariadb-prestop.sh` ensures clean cluster departure:

```bash
# Check if this node is synced (part of the cluster)
if mysql -e "SHOW STATUS LIKE 'wsrep_local_state_comment';" | grep -q "Synced"; then
    # Disable replication before shutting down
    mysql -e "SET GLOBAL wsrep_on=OFF;"
    sleep 5
    mysqladmin shutdown
fi
```

Setting `wsrep_on=OFF` before shutdown tells the cluster "I'm leaving intentionally" rather than "I crashed." This prevents the remaining nodes from trying to recover a dead node and avoids unnecessary SST when the node comes back.

### Health Checking and Auto-Healing

Our `openshift/scripts/utils/database.sh` implements sophisticated health checks:

**Sync state check** — queries `wsrep_local_state_comment` on each pod. Valid states:
- `Synced` — node is healthy and in sync
- `Donor/Desynced` — node is donating SST to a joining node (temporarily busy but healthy)
- `Joined` — node has joined but isn't fully synced yet
- `Initialized` — node is starting up

**Split-brain detection** — compares `wsrep_cluster_state_uuid` across all nodes. If nodes have different UUIDs, the cluster has split into separate partitions (see [Section 9](#9-split-brain-the-nightmare-scenario)).

**Auto-healing** — if the cluster is unhealthy, `auto_heal_galera_cluster()` scales the StatefulSet down to 1 node, waits for it to stabilize, then scales back up. This forces a clean re-bootstrap.

---

## 5. Our Future Setup: CrunchyDB PostgreSQL (Primary-Replica with Patroni)

### Architecture

```
                        ┌───────────────────────────┐
                        │  "moodle-postgres-primary" │
                        │  (Kubernetes Service)      │◄──── Moodle connects here
                        └────────────┬──────────────┘      (reads + writes)
                                     │
                                     ▼
                              ┌─────────────┐
                              │   Primary    │
                              │   (R/W)      │
                              │              │
                              │  Patroni     │
                              │  agent       │
                              └──────┬──────┘
                                     │  Streaming Replication (WAL)
                                     ▼
                              ┌─────────────┐
                              │   Replica    │
                              │   (R/O)      │
                              │              │
                              │  Patroni     │
                              │  agent       │
                              └─────────────┘

                        ┌───────────────────────────┐
                        │ "moodle-postgres-replicas" │◄──── Optional: read-only traffic
                        │  (Kubernetes Service)      │
                        └───────────────────────────┘

                        ┌───────────────────────────┐
                        │  pgBouncer (2 replicas)    │◄──── Connection pooling
                        └───────────────────────────┘
```

Unlike Galera, this is **not** multi-master. Only the primary accepts writes. The replica maintains a near-real-time copy via streaming replication.

### How PostgreSQL Streaming Replication Works

PostgreSQL uses the **Write-Ahead Log (WAL)** — every change to the database is first written to a sequential log file before it's applied to the actual data files. This guarantees crash recovery: if the server crashes mid-write, it replays the WAL on startup.

Streaming replication exploits this mechanism: the replica connects to the primary and continuously streams WAL records as they're generated.

```
Primary:
  1. Client sends INSERT
  2. PostgreSQL writes the change to WAL (sequential write — very fast)
  3. PostgreSQL applies the change to data files (heap/index pages)
  4. WAL record is streamed to replica(s)

Replica:
  1. Receives WAL record from primary
  2. Writes it to its own WAL
  3. Applies the change to its data files
  4. Now has identical data
```

The WAL is append-only and sequential, which is why streaming replication is so efficient — it's just copying a stream of bytes. Compare this to Galera's certification-based approach, which requires each node to independently validate every write-set.

### Patroni: Consensus-Based Leader Election

Patroni is the high-availability layer that sits alongside PostgreSQL on each node. It manages:

1. **Leader election** — which node is the primary
2. **Failover** — promoting a replica when the primary dies
3. **Configuration management** — applying PostgreSQL settings consistently

Patroni uses a **Distributed Configuration Store (DCS)** to coordinate. In our CrunchyDB/Kubernetes setup, the DCS is the Kubernetes API itself (using ConfigMaps or Endpoints as the consensus mechanism).

#### How Leader Election Works

```
Normal operation:
  ┌─────────────────────────────────────────┐
  │  Kubernetes DCS (ConfigMap/Endpoints)   │
  │  Leader: pod "moodle-postgres-ha-0"     │
  │  Leader lease expires: T + 30s          │
  └─────────────────────────────────────────┘
         ▲                    ▲
         │ renew lease        │ check lease
         │ every 10s          │ every 10s
  ┌──────┴──────┐      ┌──────┴──────┐
  │  ha-0       │      │  ha-1       │
  │  PRIMARY    │      │  REPLICA    │
  │  Patroni ♥  │      │  Patroni ♥  │
  └─────────────┘      └─────────────┘
```

The primary holds a **lease** in the DCS that it must renew every `loop_wait` seconds (default: 10). If it fails to renew within `ttl` seconds (default: 30), the lease expires and replicas can compete to take over.

#### Failover Sequence

```
1. Primary crashes (or network partition isolates it)
   │
2. Patroni on primary can't renew its DCS lease
   │
3. After TTL expires (30s), lease becomes available
   │
4. Patroni on replica detects orphaned lease
   │
5. Replica attempts to acquire the lease (atomic operation in K8s API)
   │
6. If successful:
   │  a. Promote PostgreSQL from replica to primary (pg_ctl promote)
   │  b. PostgreSQL opens for read-write traffic
   │  c. Kubernetes Service "moodle-postgres-primary" updates endpoints to point to new primary
   │
7. Moodle's next database connection goes to the new primary
   │
8. Total downtime: ~30-60 seconds (mostly the TTL wait)
```

This is dramatically simpler than Galera's bootstrap process. There's no "find the most up-to-date node" step because the replica was continuously streaming WAL — it's guaranteed to be very close to the primary's state (and for synchronous replication, guaranteed to be identical).

### Patroni Configuration in Our Setup

From our planned `crunchy-values.yaml`:

```yaml
patroni:
  dynamicConfiguration:
    postgresql:
      parameters:
        shared_buffers: 512MB            # PostgreSQL's main memory cache
        effective_cache_size: 2GB        # Hint to query planner about OS cache
        max_connections: 200             # Much lower than Galera's 5000 (pgBouncer handles pooling)
        work_mem: 8MB                    # Per-operation sort/hash memory
        maintenance_work_mem: 256MB      # For VACUUM, CREATE INDEX, etc.
        max_wal_size: 1GB               # WAL size before checkpoint
        wal_buffers: 16MB               # WAL write buffer
        random_page_cost: 1.1           # Tuned for SSD (default 4.0 assumes spinning disks)
        effective_io_concurrency: 200   # Parallel I/O for bitmap scans (SSD-appropriate)
        log_min_duration_statement: 5000 # Log queries slower than 5 seconds
```

Note `max_connections: 200` vs Galera's `max_connections=5000`. This isn't a downgrade — pgBouncer handles connection pooling in front of PostgreSQL (see [Section 6](#6-connection-pooling)), so PostgreSQL itself needs far fewer connections.

### Timeline and WAL Position

Every PostgreSQL instance tracks its position in the WAL as an **LSN (Log Sequence Number)** — a byte offset into the WAL stream. During failover, Patroni compares LSNs across replicas to ensure the most up-to-date replica gets promoted.

PostgreSQL also tracks **timelines** — a counter that increments every time a failover occurs. This prevents a stale ex-primary from corrupting the new primary's data if it comes back online (it would be on an old timeline and refused by the new primary).

```
Timeline 1: Primary writes A, B, C, D
                                    │ Primary crashes after D
Timeline 2:                         └──► Replica promoted, continues: E, F, G

If old primary comes back, it sees it's on Timeline 1
but the cluster is on Timeline 2. It must re-sync
from the new primary rather than accepting writes.
```

---

## 6. Connection Pooling

### The Problem

Database connections are expensive. Each PostgreSQL connection spawns a dedicated OS process (~5-10MB of memory). Each MariaDB connection spawns a thread (~256KB-1MB + buffers). When you have hundreds of PHP-FPM workers, cron jobs, and web servers, connection counts explode.

### Current Approach: No Pooling (Galera)

Our Galera setup handles this with brute force: `max_connections=5000`. MariaDB threads are lighter than PostgreSQL processes, so this works, but it's wasteful — most connections are idle most of the time.

### Future Approach: pgBouncer (CrunchyDB)

CrunchyDB includes pgBouncer, a lightweight connection pooler that sits between the application and PostgreSQL:

```
PHP-FPM workers (100+ connections)
         │
         ▼
┌──────────────────┐
│    pgBouncer     │  Maintains a pool of ~20-50 actual PostgreSQL connections
│  (2 replicas)    │  Maps incoming requests to available pooled connections
└────────┬─────────┘
         │
         ▼
┌──────────────────┐
│   PostgreSQL     │  Only sees ~20-50 connections, not 100+
│  max_conn: 200   │
└──────────────────┘
```

pgBouncer operates in three modes:
- **Session pooling** — a server connection is assigned for the life of a client connection (least efficient, most compatible)
- **Transaction pooling** — a server connection is assigned only for the duration of a transaction (most common, good balance)
- **Statement pooling** — a server connection is assigned per SQL statement (most efficient, but breaks multi-statement transactions)

Moodle works well with **transaction pooling** since it uses explicit transactions.

From our planned values:
```yaml
pgBouncer:
  replicas: 2          # HA for the pooler itself
  resources:
    requests:
      cpu: 10m         # Very lightweight — it's just shuttling bytes
      memory: 64Mi
```

---

## 7. Backup Strategies in Clustered Environments

### Current: External Backup Container (Galera)

Our Galera setup uses a separate `bcgov/backup-storage` container that connects to the database and runs backups on a schedule:

```yaml
# config/mariadb/db-backups.yaml
backupConfig: |
  mariadb=mariadb-galera:3306/moodle
  0 1 * * * default ./backup.sh -s        # Daily full backup at 1 AM
  0 4 * * * default ./backup.sh -s -v all  # Daily verification at 4 AM
```

This is a "logical backup" approach — it connects as a client and dumps the data. Simple, but:
- Slow for large databases (serializes all data through a single connection)
- Creates load on the database during backup
- Point-in-time recovery not possible (you can only restore to the backup timestamp)

### Future: pgBackRest (CrunchyDB)

pgBackRest is a purpose-built PostgreSQL backup tool integrated directly into CrunchyDB. It works with the WAL:

```
Continuous WAL archiving:
  PostgreSQL ──► WAL segments ──► pgBackRest repo (PVC/S3)
                                    │
                                    ├── Full backup (weekly, Sunday 1AM)
                                    ├── Incremental backups (daily, Mon-Sat 1AM)
                                    └── All WAL segments between backups
```

From our planned values:
```yaml
pgBackRest:
  repos:
    - name: repo1
      volume:
        volumeClaimSpec:
          storageClassName: netapp-file-backup
          accessModes: ["ReadWriteOnce"]
          resources:
            requests:
              storage: 10Gi
      schedules:
        full: "0 1 * * 0"          # Weekly full backup Sunday 1AM
        incremental: "0 1 * * 1-6"  # Daily incremental Mon-Sat 1AM
```

**Point-in-Time Recovery (PITR):** Because pgBackRest archives every WAL segment, you can restore to *any point in time*, not just backup timestamps. "Restore the database to how it was at 2:47 PM last Tuesday" is a one-command operation:

```bash
pgbackrest restore --type=time --target="2026-03-01 14:47:00"
```

**Incremental backups** only copy changed data pages since the last backup, making them much faster than full backups.

**Triggering a manual backup:**
```bash
oc annotate postgrescluster moodle-postgres \
  postgres-operator.crunchydata.com/pgbackrest-backup="$(date)" --overwrite
```

---

## 8. Failover: What Happens When a Node Dies

### Galera Failover (Current)

Galera's failover is automatic for single-node failures but manual for full cluster outages.

**Single node failure:**
```
1. Node 2 crashes
2. Remaining nodes detect missing heartbeat (within a few seconds)
3. Cluster reconfigures: nodes 0, 1, 3, 4 form a new "primary component"
   (they have a majority — 4 out of 5 — so they know they're the real cluster)
4. wsrep_cluster_size drops from 5 to 4
5. Traffic continues with zero downtime
6. When node 2 comes back, it rejoins via IST or SST
```

**Full cluster failure (all nodes down):**
```
1. All nodes are down — no one knows who has the latest data
2. MANUAL INTERVENTION REQUIRED:
   a. Check grastate.dat on each node's PVC for the highest seqno
   b. Set safe_to_bootstrap: 1 on that node
   c. Start that node with --wsrep-new-cluster
   d. Start remaining nodes to join it
3. Our deploy script automates this by always bootstrapping from node 0
   and deleting other PVCs (hence why we keep data-mariadb-galera-0)
```

### Patroni Failover (Future CrunchyDB)

Patroni failover is automatic in all scenarios.

**Primary failure:**
```
Second 0:   Primary crashes
Second 10:  Patroni on primary misses its loop_wait heartbeat renewal
Second 30:  DCS lease expires (TTL = 30s)
Second 31:  Replica's Patroni detects orphaned lease
Second 32:  Replica acquires lease, runs pg_ctl promote
Second 33:  PostgreSQL on replica opens for read-write
Second 34:  K8s Service endpoints updated → traffic flows to new primary
            ┌─────────────────────────────────────────┐
            │  Total downtime: ~30-35 seconds          │
            │  Data loss: zero (if sync replication)   │
            │  Manual intervention: none               │
            └─────────────────────────────────────────┘
```

**Replica failure:**
```
1. Replica crashes
2. Primary continues operating normally (no impact on writes or reads)
3. You temporarily lose read-only scaling and HA protection
4. When replica comes back, it reconnects and streams missing WAL
5. No manual intervention needed
```

**Both nodes fail:**
```
1. CrunchyDB Operator detects no running pods
2. Restarts pods automatically (Kubernetes restartPolicy)
3. Patroni determines which pod has the most recent data (by LSN comparison)
4. That pod becomes primary
5. Other pod becomes replica and syncs
6. No manual bootstrap procedure needed
```

This is a massive operational improvement over Galera's bootstrap problem.

---

## 9. Split-Brain: The Nightmare Scenario

Split-brain occurs when a network partition divides the cluster into two (or more) groups, and each group believes it's the real cluster and starts accepting writes independently.

```
SPLIT-BRAIN:

  ┌── Network Partition ──┐
  │                        │
  Node 0 ←→ Node 1        Node 2 ←→ Node 3 ←→ Node 4
  "We're the cluster!"    "No, WE'RE the cluster!"
  Accepting writes ✗       Accepting writes ✗

  Both sides independently write to the same tables.
  When the partition heals, the data is irreconcilably divergent.
```

### How Galera Prevents Split-Brain: Quorum

Galera uses a **quorum** (majority vote) system. After a partition, each group checks: "Do we have more than half of the last known cluster size?"

```
5-node cluster, network splits 2/3:

  Group A (2 nodes): 2/5 = 40% — NO quorum → REJECT writes, go read-only
  Group B (3 nodes): 3/5 = 60% — HAS quorum → continues operating

  When partition heals:
  Group A nodes rejoin Group B and re-sync via IST
```

This is why Galera clusters should have an odd number of nodes — with an even split (2/2), neither side has quorum and the entire cluster stops.

Our `database.sh` explicitly checks for split-brain:
```bash
# If nodes have different wsrep_cluster_state_uuid values,
# the cluster has split into separate partitions
```

### How Patroni Prevents Split-Brain: Fencing

Patroni uses a different approach. Since there's only one primary, split-brain means two nodes both think they're primary. Patroni prevents this through the DCS lease:

```
1. Primary holds the DCS lease
2. Network partition isolates the primary from the DCS (Kubernetes API)
3. Primary can't renew its lease
4. Primary's Patroni detects it lost the lease
5. Primary DEMOTES ITSELF to read-only (self-fencing)
6. Replica acquires the lease and promotes
7. Even if the old primary is still "running," it refuses writes
```

The key insight: the primary is responsible for demoting itself when it loses contact with the DCS. It doesn't wait for someone else to tell it to stop — it proactively stops accepting writes. This is called **self-fencing** and is much more robust than relying on external coordination.

---

## 10. Kubernetes and Databases

Running databases on Kubernetes adds complexity but also provides powerful primitives.

### StatefulSets

Unlike Deployments (which treat pods as interchangeable), StatefulSets provide:
- **Stable network identities** — `mariadb-galera-0`, `mariadb-galera-1`, etc. These names persist across restarts.
- **Ordered deployment** — pods start in order (0, then 1, then 2). Critical for bootstrapping.
- **Stable storage** — each pod gets its own PersistentVolumeClaim that follows it across rescheduling.

Our Galera cluster uses a StatefulSet with `podManagementPolicy: Parallel` (start all pods simultaneously) for upgrades, but `OrderedReady` for initial deployment.

### PersistentVolumeClaims (PVCs)

Each database node needs persistent storage that survives pod restarts:

```yaml
# Current (Galera): 10Gi per node × 5 nodes = 50Gi total
persistence:
  size: 10Gi

# Future (CrunchyDB): 12Gi per node × 2 nodes = 24Gi total
dataVolumeClaimSpec:
  storageClassName: netapp-block-standard
  resources:
    requests:
      storage: 12Gi
```

Our deploy script explicitly sets PVC retention policy:
```bash
oc patch statefulset $DB_DEPLOYMENT_NAME -p \
  '{"spec":{"persistentVolumeClaimRetentionPolicy":
    {"whenDeleted":"Retain","whenScaled":"Retain"}}}'
```

`Retain` means PVCs are kept even if the StatefulSet is deleted or scaled down — preventing accidental data loss.

### Operators (CrunchyDB PGO)

The Crunchy PostgreSQL Operator (PGO) is a Kubernetes operator — a custom controller that watches for `PostgresCluster` custom resources and manages the entire lifecycle:

```
You declare:                          PGO creates and manages:
┌──────────────────────┐              ┌──────────────────────┐
│  PostgresCluster CR  │              │  StatefulSets        │
│  - 2 replicas        │  ──────►     │  PVCs                │
│  - pgBackRest        │              │  Services            │
│  - pgBouncer         │              │  Secrets             │
│  - Patroni config    │              │  ConfigMaps          │
└──────────────────────┘              │  CronJobs (backups)  │
                                      │  Certificates (TLS)  │
                                      └──────────────────────┘
```

This is a significant operational upgrade from our current Galera setup, where our 260-line deploy script manually manages ConfigMaps, patches StatefulSets, handles PVC cleanup, and runs health checks. With PGO, you declare what you want and the operator makes it so.

---

## 11. Why the Migration Makes Sense

Beyond the forced deprecation of the Bitnami images, there are strong technical reasons:

| Factor | MariaDB Galera (current) | CrunchyDB PostgreSQL (future) |
|--------|------------------------|-------------------------------|
| **Nodes needed** | 5 (for quorum safety) | 2 (primary + 1 replica) |
| **Total storage** | 50Gi (5 × 10Gi) | 24Gi (2 × 12Gi) |
| **Write model** | Multi-master (all nodes) | Single primary |
| **Failover** | Automatic for 1 node; manual bootstrap for full outage | Fully automatic in all scenarios |
| **Backup** | External container, logical dumps | Integrated pgBackRest, PITR capable |
| **Connection pooling** | None (brute-force 5000 max_connections) | pgBouncer (2 replicas) |
| **Operational complexity** | 260-line deploy script + 587-line utility module + prestop hooks | Operator-managed, declarative config |
| **Split-brain protection** | Quorum-based | Self-fencing via DCS lease |
| **Moodle workload fit** | Multi-master not needed (Moodle doesn't split writes) | Primary-replica ideal for read-heavy LMS |

Moodle is a read-heavy workload — students consuming content vastly outnumber instructors creating it. Galera's multi-master capability (any node can write) was never leveraged because Moodle doesn't route queries to specific nodes. You were paying the synchronous-replication tax on every write without benefiting from distributed writes.

---

## 12. Glossary

| Term | Definition |
|------|-----------|
| **WAL** | Write-Ahead Log. PostgreSQL's transaction log — all changes are written here before being applied to data files. The foundation of crash recovery and replication. |
| **Write-set** | Galera's unit of replication — the set of row-level changes produced by a transaction. Broadcast to all nodes for certification. |
| **SST** | State Snapshot Transfer. A full copy of the database sent from a running Galera node to a joining node. |
| **IST** | Incremental State Transfer. Just the missing transactions sent from the gcache. Much faster than SST. |
| **gcache** | Galera Cache. A ring buffer on each node that stores recent write-sets for IST. |
| **Certification** | Galera's conflict detection mechanism. Each node independently validates that a write-set doesn't conflict with local transactions. |
| **Quorum** | A majority vote. In a 5-node cluster, at least 3 nodes must agree to form a functioning cluster. Prevents split-brain. |
| **Patroni** | A high-availability solution for PostgreSQL that manages leader election, failover, and configuration using a distributed consensus store. |
| **DCS** | Distributed Configuration Store. The consensus backend Patroni uses (Kubernetes API, etcd, Consul, or ZooKeeper). Stores who the current leader is. |
| **Lease / Lock** | A time-limited claim on the primary role in the DCS. Must be periodically renewed. If not renewed within the TTL, the primary loses its role. |
| **TTL** | Time To Live. How long a Patroni lease remains valid without renewal (default: 30 seconds). |
| **LSN** | Log Sequence Number. A byte offset into PostgreSQL's WAL stream, used to compare how up-to-date different nodes are. |
| **Timeline** | A counter in PostgreSQL that increments on each failover. Prevents a stale ex-primary from corrupting the new primary's data. |
| **PITR** | Point-In-Time Recovery. Restoring a database to an arbitrary timestamp using base backups + WAL archives. |
| **pgBackRest** | A purpose-built PostgreSQL backup tool supporting full, incremental, and differential backups with WAL archiving. |
| **pgBouncer** | A lightweight PostgreSQL connection pooler that reduces the number of actual database connections needed. |
| **PGO** | PostgreSQL Operator (Crunchy). A Kubernetes operator that manages the full lifecycle of PostgreSQL clusters. |
| **StatefulSet** | A Kubernetes workload API for applications that need stable identities and persistent storage (ideal for databases). |
| **PVC** | PersistentVolumeClaim. A Kubernetes request for durable storage that survives pod restarts. |
| **Fencing / Self-fencing** | Preventing a node from accepting writes when it shouldn't. Self-fencing means a node demotes itself when it loses contact with the consensus store. |
| **Split-brain** | A failure mode where two groups of nodes independently accept writes, causing irreconcilable data divergence. |
| **Flow control** | Galera's mechanism for slowing down fast nodes so slow nodes can keep up, preventing apply queue overflow. |
| **Streaming replication** | PostgreSQL's mechanism for continuously shipping WAL records from primary to replica(s) over a persistent TCP connection. |
