# Galera Cluster Troubleshooting Guide

## Symptom

Moodle intermittently shows "Error reading from database" — typically every Nth page load.

## Step 1: Check all nodes

Run this for each node (0 through 4):

```bash
oc exec mariadb-galera-{N} -- mariadb -u root -p'YOUR_PASSWORD' -e "SHOW STATUS LIKE 'wsrep_cluster_size'; SHOW STATUS LIKE 'wsrep_local_state_comment';"
```

## Step 2: Interpret the results

| `wsrep_local_state_comment` | `wsrep_cluster_size` | Meaning |
|---|---|---|
| **Synced** | Matches other nodes | Healthy |
| **Donor/Desynced** | Matches other nodes | Currently sending SST to another node — temporary, wait it out |
| **Joined** | Matches other nodes | Catching up on recent transactions — almost there, wait |
| **Joining** | Matches other nodes | Receiving SST — wait, can take several minutes |
| **Initialized** | 0 | **Problem.** Node failed to join the cluster |
| **Initialized** | 1 | **Problem.** Node thinks it's alone — isolated |

## Step 3: Fix a stuck node

If a node shows `Initialized` with `cluster_size: 0`:

```bash
# Delete the pod — Kubernetes will recreate it
oc delete pod mariadb-galera-{N}
```

Watch it come back:

```bash
oc get pods -w -l app.kubernetes.io/name=mariadb-galera
```

Wait for `READY: 1/1`, then re-run the check from Step 1.

## Step 4: If the node won't sync after restart

Check if it's a disk space issue:

```bash
# Check PVC usage on the stuck node
oc exec mariadb-galera-{N} -- df -h /bitnami/mariadb/data
```

If the PVC is nearly full, SST will fail because it needs enough space to copy the entire dataset. You'll need to expand the PVC in the OpenShift console before the node can sync.

Also check the logs for SST errors:

```bash
oc logs mariadb-galera-{N} | grep -i -E "sst|wsrep|error" | tail -40
```

## Step 5: Nuclear option — if multiple nodes are broken

If 2+ nodes are stuck and deleting pods doesn't fix them:

```bash
# 1. Scale to just the primary node
oc scale sts/mariadb-galera --replicas=1

# 2. Wait for node 0 to be ready
oc get pods -w -l app.kubernetes.io/name=mariadb-galera

# 3. Verify node 0 is healthy
oc exec mariadb-galera-0 -- mariadb -u root -p'YOUR_PASSWORD' -e "SHOW STATUS LIKE 'wsrep_local_state_comment';"

# 4. Scale back up one node at a time
oc scale sts/mariadb-galera --replicas=2
# Wait for node 1 to show 1/1 READY, then:
oc scale sts/mariadb-galera --replicas=3
# Repeat until all nodes are back
```

Scaling up one at a time avoids the race condition where multiple nodes try to SST simultaneously.

## Key rules

- **Don't redeploy to fix a DB issue.** Every deployment restarts the destructive Galera cycle (scale to 0, delete PVCs, rebuild).
- **Don't rush.** Let SST finish before taking further action. Large datasets can take several minutes.
- **Check disk space first** if a node repeatedly fails to join — a full PVC is the silent killer.
