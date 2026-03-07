# Phase 2: Replace Bitnami Redis with Official Redis Images + Additional Improvements

## Context

The Moodle deployment uses Bitnami Redis images (`bitnamilegacy/redis:8.0.2-debian-12-r2` and `bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1`) deployed via the Bitnami Redis Helm chart (v23.1.3). As with the MariaDB images addressed in Phase 1, these `bitnamilegacy` images are archived with no security updates following Broadcom's deprecation of free Bitnami containers.

Unlike the database migration (Phase 1), this is an **image and deployment method replacement** — Redis stays as the caching/session engine. The architecture (Sentinel HA + proxy) remains the same; only the container images and how they're deployed change.

This document also includes additional infrastructure improvements identified during the Phase 1 analysis.

---

## Part A: Redis Image and Deployment Replacement

### Step 1: Replace Bitnami Redis Images with Official Redis

The official `redis` Docker image (from Docker Hub / Redis Ltd) supports the same Sentinel capabilities without Bitnami-specific assumptions about init containers, volume permissions, and security contexts.

#### New image references (`example.versions.env`):

| Current | Replacement |
|---------|------------|
| `bitnamilegacy/redis:8.0.2-debian-12-r2` | `redis:8-alpine` |
| `bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1` | `redis:8-alpine` (same image, sentinel is a built-in mode) |

The official Redis image includes `redis-sentinel` as a built-in binary — no separate sentinel image is needed. Sentinel is started with `redis-sentinel /path/to/sentinel.conf` or `redis-server --sentinel`.

#### Files to modify:

**`example.versions.env` (lines 43-46)**
```env
# Replace:
REDIS_HELM_CHART=bitnami/redis
REDIS_CHART_VERSION=23.1.3
REDIS_IMAGE=bitnamilegacy/redis:8.0.2-debian-12-r2
REDIS_SENTINEL_IMAGE=bitnamilegacy/redis-sentinel:8.0.2-debian-12-r1

# With:
REDIS_IMAGE=redis:8-alpine
```

**`docker-common.yml`** — No Redis changes needed (Redis is in `docker-redis.yml`)

---

### Step 2: Replace Bitnami Helm Chart with Custom Manifests

The Bitnami Redis Helm chart carries significant Bitnami-specific complexity (custom init containers for volume permissions, Bitnami-specific environment variables like `REDIS_REPLICATION_MODE`, custom health checks). Rather than fighting this with the official Redis image, write clean OpenShift manifests.

#### New files to create:

**`openshift/redis/redis-configmap.yaml`** — Redis server configuration:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: redis-config
data:
  redis.conf: |
    bind 0.0.0.0
    protected-mode no
    port 6379
    tcp-keepalive 300
    loglevel notice
    appendonly yes
    save ""
    maxmemory-policy allkeys-lru
    rename-command FLUSHDB ""
    rename-command FLUSHALL ""

  sentinel.conf: |
    port 26379
    sentinel monitor mymaster redis-node-0.redis-headless 6379 2
    sentinel down-after-milliseconds mymaster 60000
    sentinel failover-timeout mymaster 18000
    sentinel parallel-syncs mymaster 1
    sentinel resolve-hostnames yes
```

**`openshift/redis/redis-statefulset.yaml`** — StatefulSet with two containers per pod (Redis + Sentinel):
- Image: `redis:8-alpine` (pulled through Artifactory: `artifacts.developer.gov.bc.ca/docker-remote/redis:8-alpine`)
- Redis container: port 6379, runs `redis-server /etc/redis/redis.conf`
- Sentinel container: port 26379, runs `redis-sentinel /etc/redis/sentinel.conf`
- `emptyDir` volumes (no PVCs needed — Redis is used as a cache/session store, not persistent data)
- Resource requests/limits matching current: CPU 20m/150m, Memory 128Mi/256Mi
- SecurityContext compatible with OpenShift `restricted-v2` SCC (no runAsUser, let OpenShift assign)
- Readiness probe: `redis-cli ping`
- Liveness probe: `redis-cli ping` with initialDelaySeconds: 30
- Replica replication configured via init script that checks pod ordinal:
  - Pod 0: starts as master
  - Pod 1+: starts with `replicaof redis-node-0.redis-headless 6379`

**`openshift/redis/redis-headless-service.yaml`** — Headless service for StatefulSet DNS:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis-headless
spec:
  clusterIP: None
  selector:
    app: redis
  ports:
    - name: redis
      port: 6379
    - name: sentinel
      port: 26379
```

**`openshift/redis/redis-service.yaml`** — ClusterIP service for client access (optional, proxy handles routing):
```yaml
apiVersion: v1
kind: Service
metadata:
  name: redis
spec:
  selector:
    app: redis
  ports:
    - name: redis
      port: 6379
    - name: sentinel
      port: 26379
```

#### Files to delete (after migration):
- `config/redis/values.yml` (Bitnami Helm values — 500+ lines)
- `config/redis/redis-cluster-values.yml`
- `config/redis/redis-upgrade-cluster-values.yml`

---

### Step 3: Rewrite Redis Deployment Script

**`openshift/scripts/deploy-redis-sentinel.sh`** — Complete rewrite (currently 486 lines):

The new script should:
1. Apply the ConfigMap, headless Service, and StatefulSet manifests via `oc apply -f`
2. Wait for all pods to reach Running state
3. Verify master election via `redis-cli -h redis-node-0.redis-headless -p 26379 sentinel master mymaster`
4. Generate the sentinel tunnel proxy config JSON (reuse existing `generate_redis_proxy_config_json()` from `utils/redis.sh`)
5. Deploy or restart the Redis proxy deployment
6. Verify proxy connectivity

Key simplifications:
- No Helm install/upgrade — direct `oc apply`
- No Bitnami-specific probe fixes (official image works with standard probes)
- No image resolution complexity (single image reference)
- Startup probe removal workarounds are eliminated

#### Files to modify:

**`openshift/scripts/utils/redis.sh` (494 lines)** — Partial updates:
- `remove_redis_startup_probe()` — Remove (no longer needed)
- `remove_all_redis_probes()` — Remove
- `apply_redis_probe_fixes()` — Remove
- `generate_redis_proxy_config_json()` — Keep but update pod naming convention if it changes
- `wait_for_redis_sync()` — Keep, update to use `redis-cli ping` instead of Bitnami health checks
- `create_redis_services()` — Simplify (headless service covers pod DNS)
- `test_redis_proxy_connectivity()` — Keep as-is

---

### Step 4: Update Redis Proxy Dockerfile

**`Redis.Proxy.Dockerfile`** — Currently uses `golang:1.12` (very old) for building the sentinel_tunnel tool.

Update:
```dockerfile
# Build stage
ARG GOLANG_FROM_IMAGE=golang:1.22-alpine
FROM ${GOLANG_FROM_IMAGE} AS builder
# ... (same sentinel_tunnel build)

# Runtime stage
ARG UBUNTU_FROM_IMAGE=ubuntu:24.04
FROM ${UBUNTU_FROM_IMAGE}
# ... (same runtime setup)
```

Also update `example.versions.env`:
```env
GOLANG_IMAGE=golang:1.22-alpine  # was golang:1.12
```

> **Note**: The sentinel_tunnel tool from `github.com/RedisLabs/sentinel_tunnel` was last updated in 2020. If it doesn't compile with Go 1.22, consider alternatives like [redis-sentinel-proxy](https://github.com/flant/redis-sentinel-proxy) or HAProxy with sentinel integration. Test compilation first.

---

### Step 5: Update CI/CD Pipeline

**`.github/workflows/helm-images.yml`**
- Remove `REDIS_IMAGE` and `REDIS_SENTINEL_IMAGE` from the `IMAGES_TO_CACHE` array (lines 99-103, 146-151)
- Add the official `redis:8-alpine` image to the cache list instead (single image vs two)

**`.github/workflows/build.yml`**
- Remove `REDIS_HELM_CHART` and related outputs from `checkEnv` (lines 112-113)
- The `redis-proxy` build job remains unchanged (it builds the proxy, not Redis itself)

**`.github/workflows/deploy.yml`**
- Update the "Deploy Redis Sentinel Helm Chart" step (line 224-243):
  - Change name to "Deploy Redis Sentinel"
  - Call updated `deploy-redis-sentinel.sh`
  - Remove `REDIS_HELM_CHART` environment variable
  - Remove Bitnami-specific variables (`REDIS_CHART_VERSION`)

**`example.env`**
- Remove `REDIS_REPO=oci://registry-1.docker.io/` (line 37)
- Keep `REDIS_NAME`, `REDIS_PROXY_NAME`, `REDIS_HOST`, `REDIS_URL`, `REDIS_PORT` as-is (architecture unchanged)

---

### Step 6: Update Local Development Environment

**`docker-redis.yml`** — Update image references:

Replace all Bitnami Redis images with `redis:8-alpine`:

```yaml
services:
  redis-primary:
    image: redis:8-alpine
    command: >
      redis-server
      --appendonly yes
      --save ""
      --protected-mode no
      --bind 0.0.0.0
    # ... (rest stays similar)

  redis-secondary-1:
    image: redis:8-alpine
    command: >
      redis-server
      --appendonly yes
      --save ""
      --protected-mode no
      --replicaof redis-primary 6379
    # ...

  sentinel-1:
    image: redis:8-alpine
    command: >
      redis-sentinel /etc/redis/sentinel.conf
    volumes:
      - ./config/redis/sentinel-local.conf:/etc/redis/sentinel.conf
    # ...
```

Create **`config/redis/sentinel-local.conf`**:
```
port 26379
sentinel monitor mymaster 172.99.0.10 6379 2
sentinel down-after-milliseconds mymaster 5000
sentinel failover-timeout mymaster 5000
sentinel parallel-syncs mymaster 1
sentinel resolve-hostnames yes
```

The current local dev uses inline sentinel config via Docker `command:` — switching to a config file is cleaner and matches the OpenShift approach.

---

### Step 7: Moodle Configuration

**No changes needed** — the Redis session and cache configuration in Moodle config files is Redis-server-agnostic. The connection parameters (host, port, database number) remain the same because the Redis Proxy continues to front the Sentinel cluster on the same port.

Files that remain unchanged:
- `config/moodle/remote.config.php` — session_redis_host/port stay the same
- `config/moodle/local.config.php` — session handler stays file-based for local dev
- `config/cron/remote.config.php` — no Redis session config (cron doesn't need sessions)
- `config/php/php-fpm.conf` — session.save_path stays the same
- Custom cache store plugin (`config/moodle/plugins/cache/stores/redisfile/`) — stays the same

---

## Part B: Additional Infrastructure Improvements

### Improvement 1: Switch Database PVCs to Block Storage

**Current**: All PVCs use `netapp-file-standard` storage class.
**Recommended**: Database PVCs should use `netapp-block-standard`.

BC Gov documentation states: *"netapp-block-standard is generally more performant for database or other small transaction/write intensive application uses."*

This applies to the CrunchyDB PostgreSQL PVCs created in Phase 1. The `crunchy-values.yaml` in the Phase 1 plan already specifies `netapp-block-standard`.

Moodle data PVCs (`moodle-data`, `moodle-app-data`, `moodle-shared`) should remain on `netapp-file-standard` since they need `ReadWriteMany` access mode for multi-pod access, and block storage only supports `ReadWriteOnce`.

**Files**: Already addressed in Phase 1's `config/postgres/crunchy-values.yaml`.

---

### Improvement 2: Add Network Policies

The deployment currently has **no NetworkPolicy resources**. On the BC Gov OpenShift platform, this means all pods in the namespace can communicate with all other pods in all namespaces within the cluster. This is unusual for a production workload.

#### New file to create:

**`openshift/network-policies.yaml`**:

```yaml
# Deny all ingress by default
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-all-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress

---
# Allow ingress from OpenShift router to web pods
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-router-to-web
spec:
  podSelector:
    matchLabels:
      deployment: web
  ingress:
    - from: []  # OpenShift router uses host networking
      ports:
        - port: 8080

---
# Allow web (nginx) to PHP
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-web-to-php
spec:
  podSelector:
    matchLabels:
      deployment: php
  ingress:
    - from:
        - podSelector:
            matchLabels:
              deployment: web
      ports:
        - port: 9000

---
# Allow PHP/Cron to PostgreSQL
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-postgres
spec:
  podSelector:
    matchLabels:
      postgres-operator.crunchydata.com/cluster: moodle-postgres
  ingress:
    - from:
        - podSelector:
            matchLabels:
              deployment: php
        - podSelector:
            matchLabels:
              app: cron
      ports:
        - port: 5432

---
# Allow PHP/Cron to Redis Proxy
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-to-redis
spec:
  podSelector:
    matchLabels:
      app: redis-proxy
  ingress:
    - from:
        - podSelector:
            matchLabels:
              deployment: php
        - podSelector:
            matchLabels:
              app: cron
      ports:
        - port: 6379

---
# Allow Redis Proxy to Redis StatefulSet
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-proxy-to-redis
spec:
  podSelector:
    matchLabels:
      app: redis
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: redis-proxy
        - podSelector:
            matchLabels:
              app: redis  # Inter-node replication and sentinel
      ports:
        - port: 6379
        - port: 26379

---
# Allow PostgreSQL inter-pod communication (Patroni)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-postgres-internal
spec:
  podSelector:
    matchLabels:
      postgres-operator.crunchydata.com/cluster: moodle-postgres
  ingress:
    - from:
        - podSelector:
            matchLabels:
              postgres-operator.crunchydata.com/cluster: moodle-postgres
      ports:
        - port: 5432
        - port: 8008  # Patroni REST API
        - port: 2022  # pgBackRest
```

#### Deployment:
Add `oc apply -f openshift/network-policies.yaml` to the `deploy-template.sh` script, early in the deployment flow (before scaling up pods).

> **Important**: Test thoroughly in dev first. Incorrect network policies can break the entire application. Start with the `deny-all-ingress` policy disabled, add allow rules one at a time, verify each service still communicates, then enable the default deny.

---

### Improvement 3: Upgrade Golang for Redis Proxy Build

The Redis Proxy Dockerfile uses `golang:1.12` which is **7 years old** (released Feb 2019). This is a supply chain risk.

**`example.versions.env`**:
```env
GOLANG_IMAGE=golang:1.22-alpine  # was golang:1.12
```

**`Redis.Proxy.Dockerfile`**:
```dockerfile
ARG GOLANG_FROM_IMAGE=golang:1.22-alpine
```

The sentinel_tunnel source code is simple Go and should compile fine on modern Go versions, but test compilation during implementation.

---

### Improvement 4: Mirror All Images to Artifactory

Ensure every external image is pulled through `artifacts.developer.gov.bc.ca` to avoid Docker Hub rate limits and gain Xray security scanning. The project already does this for most images, but verify completeness.

#### Current image pull paths to verify:

| Image | Should pull from |
|-------|-----------------|
| `redis:8-alpine` | `artifacts.developer.gov.bc.ca/docker-remote/redis:8-alpine` |
| `postgres:17-alpine` (local dev) | `artifacts.developer.gov.bc.ca/docker-remote/postgres:17-alpine` |
| `golang:1.22-alpine` (build) | `artifacts.developer.gov.bc.ca/docker-remote/golang:1.22-alpine` |
| `php:8.1-fpm` | Already via Artifactory |
| `nginxinc/nginx-unprivileged:1-alpine-slim` | Already via Artifactory |
| `ubuntu:24.04` | Already via Artifactory |

The `helm-images.yml` workflow already handles caching images to Artifactory. Update it to include the new `redis:8-alpine` image.

---

### Improvement 5: Consider PHP 8.3+ Upgrade

The deployment currently uses `php:8.1-fpm`. PHP 8.1 reaches **end of life in December 2025** (security fixes only, already past active support). Moodle 4.5 supports PHP 8.1-8.3.

This is **not part of this phase** but should be planned as a follow-up:
- Update `PHP_IMAGE=php:8.3-fpm` and `CRON_IMAGE=php:8.3-cli` in `example.versions.env`
- Test all plugins for PHP 8.3 compatibility
- The PHP compatibility validation workflow (`.github/workflows/build.yml` line 208-225) should catch issues

---

## Files Summary

### New files to create:
| File | Purpose |
|------|---------|
| `openshift/redis/redis-configmap.yaml` | Redis server + sentinel configuration |
| `openshift/redis/redis-statefulset.yaml` | Redis StatefulSet (replaces Helm chart) |
| `openshift/redis/redis-headless-service.yaml` | Headless service for pod DNS |
| `openshift/redis/redis-service.yaml` | ClusterIP service |
| `openshift/network-policies.yaml` | Network segmentation policies |
| `config/redis/sentinel-local.conf` | Local dev sentinel config file |

### Files to modify:
| File | Change |
|------|--------|
| `example.versions.env` | Replace Bitnami Redis refs with `redis:8-alpine`, upgrade Golang |
| `example.env` | Remove `REDIS_REPO`, remove Helm chart refs |
| `openshift/scripts/deploy-redis-sentinel.sh` | Rewrite for `oc apply` instead of Helm |
| `openshift/scripts/utils/redis.sh` | Remove Bitnami probe workarounds |
| `Redis.Proxy.Dockerfile` | Upgrade Golang base image |
| `.github/workflows/helm-images.yml` | Update cached images list |
| `.github/workflows/deploy.yml` | Remove Helm chart inputs for Redis |
| `.github/workflows/build.yml` | Remove Redis Helm chart outputs |
| `docker-redis.yml` | Replace Bitnami images with `redis:8-alpine` |
| `openshift/scripts/deploy-template.sh` | Add network policy application |

### Files to delete (after migration):
| File | Reason |
|------|--------|
| `config/redis/values.yml` | Bitnami Helm values |
| `config/redis/redis-cluster-values.yml` | Bitnami cluster values |
| `config/redis/redis-upgrade-cluster-values.yml` | Bitnami upgrade values |
| `docker-phpmyadmin.yml` | MariaDB tool (replace with pgAdmin in Phase 1) |

### Files that stay unchanged:
| File | Reason |
|------|--------|
| `config/moodle/remote.config.php` | Redis connection params unchanged |
| `config/moodle/local.config.php` | Uses file sessions locally |
| `config/redis/sentinel_tunnel.local.config.json` | Proxy config format unchanged |
| `config/redis/sentinel_tunnel.remote.config.json` | Auto-generated at deploy time |
| `config/redis/redis-stats.php` | Monitoring dashboard works with any Redis |
| `config/redis/entrypoint` | Proxy entrypoint unchanged |
| `config/moodle/plugins/cache/stores/redisfile/` | Cache plugin is Redis-server-agnostic |

---

## Verification Plan

### Local development:
1. `docker compose down -v`
2. `docker compose -f docker-compose.yml -f docker-redis.yml up redis-primary redis-secondary-1 sentinel-1 sentinel-2 sentinel-3 redis-proxy`
3. Verify sentinel detects master: `docker exec sentinel-1 redis-cli -p 26379 sentinel master mymaster`
4. Verify proxy routes correctly: `docker exec redis-proxy redis-cli -h localhost -p 6450 ping`
5. Start Moodle, verify sessions work (login/logout cycle)

### Dev namespace (950003-dev):
1. Apply Redis manifests: `oc apply -f openshift/redis/`
2. Verify StatefulSet pods all reach Running state
3. Verify sentinel master election: `oc exec redis-node-0 -- redis-cli -p 26379 sentinel master mymaster`
4. Verify replication: `oc exec redis-node-0 -- redis-cli info replication` (should show connected_slaves > 0)
5. Restart redis-proxy deployment to pick up new config
6. Verify Moodle sessions work (login, navigate, logout)
7. Test failover: `oc delete pod redis-node-0` — verify sentinel promotes a new master and Moodle sessions survive

### Network policies (if implemented):
1. Apply policies one at a time in dev
2. After each policy, verify the allowed paths still work:
   - Browser → nginx → PHP (web access)
   - PHP → PostgreSQL (database queries)
   - PHP → Redis proxy → Redis (sessions/cache)
   - Cron → PostgreSQL (cron jobs)
   - Redis node → Redis node (replication)
3. Verify that a pod NOT in the allow list cannot reach protected services

### CI/CD:
1. Push to `950003-dev` branch
2. Verify `helm-images` job caches `redis:8-alpine` to Artifactory
3. Verify `deploy-redis-sentinel.sh` applies manifests successfully
4. Verify proxy deployment restarts cleanly
5. Verify Moodle comes up with working sessions

---

## Risk Mitigation

1. **Session loss during migration**: Redis is ephemeral cache/session storage. Users will need to re-login after the Redis migration. Schedule during low-traffic window. No data loss risk.
2. **Sentinel tunnel compatibility**: The `sentinel_tunnel` Go tool is generic — it talks standard Redis Sentinel protocol, not Bitnami-specific. Should work unchanged with official Redis images.
3. **OpenShift security context**: Official `redis:8-alpine` runs as any user by default, compatible with OpenShift's `restricted-v2` SCC. No `runAsUser` specification needed.
4. **Rollback**: Keep the Bitnami Helm release intact until the new StatefulSet is proven. Rollback = delete new StatefulSet, scale up old Helm-managed StatefulSet.
5. **Network policies**: Deploy incrementally. A misconfigured policy can break the entire app. Test each rule individually in dev before combining.

---

## Recommended Execution Order

1. Phase 1 (database migration) should be completed and stable in at least dev before starting Phase 2
2. Within Phase 2:
   - Start with local dev Redis replacement (lowest risk, fastest feedback)
   - Then deploy to dev namespace
   - Upgrade Golang in Redis Proxy Dockerfile
   - Add network policies last (highest risk of breaking things)
3. PHP 8.3 upgrade should be a separate effort after both phases are complete
