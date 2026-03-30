# Phase 1: Migrate MariaDB Galera to CrunchyDB PostgreSQL

## Context

The Moodle deployment on OpenShift (Silver cluster, 950003-dev/test/prod) currently uses Bitnami MariaDB Galera images (`bitnamilegacy/mariadb-galera:10.6`) deployed via the Bitnami Helm chart. Broadcom deprecated free versioned Bitnami images in August 2025 — the `bitnamilegacy` registry is a read-only archive with no security patches. This is a security and operational risk.

BC Gov best practices recommend **CrunchyDB PostgreSQL** as the standard HA database on OpenShift. The Crunchy PostgreSQL Operator (PGO v5.8.5) is already installed on the Silver cluster. Moodle fully supports PostgreSQL as a first-class database engine. The bcgov team maintains a tested Helm chart at `https://bcgov.github.io/crunchy-postgres/`.

**Goal**: Replace MariaDB Galera with CrunchyDB PostgreSQL across infrastructure, application, CI/CD, local dev, and migrate existing data using pgloader.

---

## Step 1: Add PostgreSQL PHP Extensions to All Dockerfiles

Currently only `pdo_mysql` and `mysqli` are installed. We need to add `pdo_pgsql` and `pgsql`, and can remove the MySQL extensions once migration is complete (or keep both during transition).

### Files to modify:

**`PHP.Dockerfile` (line 47-61)**
- Add `pdo_pgsql` and `pgsql` to the `install-php-extensions` block
- Keep `pdo_mysql` and `mysqli` temporarily for the transition period

**`Moodle.Dockerfile` (line 62-77)**
- Same change — add `pdo_pgsql` and `pgsql` to the extensions list

**`CRON.Dockerfile` (line 16-17)**
- Add `pdo_pgsql` and `pgsql` to the `install-php-extensions` call

### Also install the `libpq-dev` system dependency:
- Add `libpq-dev` to the `apt-get install` blocks in all three Dockerfiles (the `install-php-extensions` helper may handle this automatically, but explicit is safer)

---

## Step 2: Update Moodle Configuration Files for PostgreSQL

### Files to modify:

**`config/moodle/remote.config.php` (production — line 13-18, 54-61)**
```php
// Change from:
$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
// To:
$CFG->dbtype    = 'pgsql';
$CFG->dblibrary = 'native';
```
Update `dboptions` (line 54-61):
```php
$CFG->dboptions = array(
    'dbpersist' => 0,
    'dbport' => '5432',
    'dbsocket' => '',
    'dbcollation' => 'utf8mb4_unicode_ci',  // Moodle handles this for pgsql
    'logslow'  => 5,
    'logerrors'  => true,
);
```

**`config/moodle/local.config.php` (local dev — line 10, 29-35)**
- Same `dbtype` change to `pgsql`
- Update `dboptions` port to `5432`

**`config/cron/remote.config.php` (cron — line 63, 83-89)**
- Same `dbtype` change to `pgsql`
- Update `dboptions` port to `5432`

---

## Step 3: Create CrunchyDB PostgreSQL Deployment

### New files to create:

**`config/postgres/crunchy-values.yaml`** — Helm values for the bcgov crunchy-postgres chart:
```yaml
fullnameOverride: moodle-postgres

crunchyImage: artifacts.developer.gov.bc.ca/bcgov-docker-local/crunchy-postgres:ubi9-17.4-0

postgresVersion: 17

instances:
  - name: ha
    replicas: 2
    dataVolumeClaimSpec:
      storageClassName: netapp-block-standard   # BC Gov recommended for databases
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 12Gi
    resources:
      requests:
        cpu: 50m
        memory: 256Mi
      limits:
        cpu: "2"
        memory: 4Gi

users:
  - name: moodle
    databases: [moodle]
    options: "SUPERUSER"   # Needed for Moodle install/upgrade

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
        full: "0 1 * * 0"      # Weekly full backup Sunday 1AM
        incremental: "0 1 * * 1-6"  # Daily incremental Mon-Sat 1AM

pgBouncer:
  replicas: 2
  resources:
    requests:
      cpu: 10m
      memory: 64Mi

patroni:
  dynamicConfiguration:
    postgresql:
      parameters:
        shared_buffers: 512MB
        effective_cache_size: 2GB
        max_connections: 200
        work_mem: 8MB
        maintenance_work_mem: 256MB
        max_wal_size: 1GB
        wal_buffers: 16MB
        random_page_cost: 1.1
        effective_io_concurrency: 200
        log_min_duration_statement: 5000
```

**`openshift/scripts/deploy-crunchy-postgres.sh`** — New deployment script replacing `deploy-mariadb-galera.sh`:
- Add the bcgov crunchy-postgres Helm repo
- `helm upgrade --install` using the values file
- Wait for PostgresCluster CR to report ready
- Verify database connectivity using `psql` instead of `mysql`
- Verify Moodle database exists and has data

### Files to delete (after migration is complete):
- `openshift/scripts/deploy-mariadb-galera.sh` (260 lines)
- `openshift/scripts/mariadb-prestop.sh` (42 lines)
- `config/mariadb/galera-values.yaml` (1068 lines)
- `config/mariadb/my.cnf` (127 lines)
- `config/mariadb/config.yaml` (236 lines)
- `config/mariadb/mariadb-galera-prestop-patch.json` (36 lines)
- `config/mariadb/db-backups.yaml` (31 lines)
- `openshift/mariadb-galera.yml` (12 lines)
- `openshift/mariadb.yml` (31 lines)

---

## Step 4: Update Database Utilities

**`openshift/scripts/utils/database.sh` (587 lines)** — This file is heavily MariaDB/Galera-specific. Needs significant rewrite:

- Replace all `mysql`/`mariadb` CLI calls with `psql` equivalents
- Replace Galera health checks (`wsrep_local_state_comment`, `wsrep_cluster_size`) with Patroni health checks (CrunchyDB uses Patroni for HA)
- Patroni health endpoint: `curl http://<pod>:8008/health` returns JSON with role and state
- Replace `wait_for_galera_sync()` with `wait_for_patroni_sync()` that checks all replicas report `running` state and `timeline` matches primary
- Replace `check_galera_cluster_health()` with Patroni-based checks
- Remove `auto_heal_galera_cluster()` — CrunchyDB operator handles failover automatically
- Keep `should_migrate_by_version()` — it's database-agnostic
- Update `manage_backup_storage_secrets()` — change key names from `MARIADB_*` to `PGUSER`/`PGPASSWORD`
- Update credential retrieval: CrunchyDB creates a secret named `<cluster>-pguser-<username>` containing `user`, `password`, `dbname`, `host`, `port`, `uri`, `jdbc-uri`

---

## Step 5: Update CI/CD Pipelines

### Files to modify:

**`example.env` (line 34, 52-74)**
- Change `DB_DEPLOYMENT_NAME=mariadb-galera` → `DB_DEPLOYMENT_NAME=moodle-postgres`
- Change `DB_HOST='mariadb-galera'` → `DB_HOST='moodle-postgres-primary'` (CrunchyDB service naming convention: `<name>-primary` for read-write, `<name>-replicas` for read-only)
- Change `DB_HOST_SERVICE='mariadb-galera'` → `DB_HOST_SERVICE='moodle-postgres-primary'`
- Change `DB_PORT=3306` → `DB_PORT=5432`
- Remove all `MARIADB_*` and `MYSQL_*` variables
- Remove `MARIADB_GALERA_*` variables

**`example.versions.env` (line 41)**
- Remove `MARIADB_IMAGE=bitnamilegacy/mariadb-galera:10.6`
- Add `CRUNCHY_POSTGRES_CHART_VERSION=0.5.0`
- Change `BACKUP_IMAGE=bcgovimages/backup-container-mariadb:latest` → remove (CrunchyDB handles backups via pgBackRest natively)

**`.github/workflows/build.yml`**
- Remove the `helm-images` job dependency for MariaDB image (line 370-375) — CrunchyDB images are pre-built on the cluster, no need to push to Artifactory
- Remove `MARIADB_IMAGE` from `checkEnv` outputs (line 108)
- Update deploy workflow call to pass new DB variables

**`.github/workflows/deploy.yml` (line 204-221)**
- Replace the "Deploy Database StatefulSet" step to call `deploy-crunchy-postgres.sh` instead of `deploy-mariadb-galera.sh`
- Remove `MARIADB_IMAGE` input (line 54-55)
- Update environment variables passed to the deploy step
- Update backup deployment to remove MariaDB-specific backup (CrunchyDB has pgBackRest built in)

**`.github/workflows/helm-images.yml`**
- Remove MariaDB image from the `IMAGES_TO_CACHE` array (line 100, 146-148)
- Remove `MARIADB_IMAGE` references throughout

**`openshift/template.json`**
- Update the `moodle-secrets` secret to use PostgreSQL credential key names
- Service definitions: replace MariaDB service with CrunchyDB service references (CrunchyDB operator creates services automatically, so manual service definitions may be removed)

---

## Step 6: Update Backup Strategy

CrunchyDB includes **pgBackRest** for automated backups — this replaces the separate `bcgov/backup-storage` Helm chart deployment.

### Files to modify:
- **`openshift/scripts/deploy-database-backups.sh`** — Remove or significantly simplify. pgBackRest is configured declaratively in the `PostgresCluster` CR via `crunchy-values.yaml`. The backup schedule is defined in Step 3. Manual backups can be triggered with:
  ```bash
  oc annotate postgrescluster moodle-postgres postgres-operator.crunchydata.com/pgbackrest-backup="$(date)" --overwrite
  ```
- **`config/mariadb/db-backups.yaml`** — Delete (replaced by pgBackRest config in crunchy-values.yaml)

---

## Step 7: Update Local Development Environment

### Files to modify:

**`docker-common.yml` (line 85-98)** — Replace MariaDB service:
```yaml
db:
  image: postgres:17-alpine
  restart: no
  deploy:
    replicas: 0
  env_file: example.env
  environment:
    POSTGRES_USER: ${DB_USER:-moodle}
    POSTGRES_PASSWORD: ${DB_PASSWORD:-moodle}
    POSTGRES_DB: ${DB_NAME:-moodle}
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-moodle} -d ${DB_NAME:-moodle}"]
    interval: 10s
    timeout: 5s
    retries: 5
```

**`docker-compose.yml` (line 37-53)** — Update db-0 service:
- Change port from `3306:3306` → `5432:5432`
- Change volume from `mysqldata-0:/var/lib/mysql` → `pgdata-0:/var/lib/postgresql/data`
- Remove `command: --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci`
- Update volume definition from `mysqldata-0: {}` → `pgdata-0: {}`

**`docker-compose.yml` (line 60-93)** — Update php-0 and cron-0:
- Change `DB_HOST: db-0` (stays the same)
- Links stay the same

**`docker-phpmyadmin.yml`** — Remove or replace with pgAdmin:
```yaml
services:
  pgadmin:
    image: dpage/pgadmin4:latest
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@local.dev
      PGADMIN_DEFAULT_PASSWORD: admin
    ports:
      - "5050:80"
```

---

## Step 8: Data Migration Using pgloader (dev namespace first)

This step is performed manually in the `950003-dev` namespace. It is NOT automated in CI/CD.

### Pre-migration steps:
1. Put Moodle in maintenance mode
2. Take a full MariaDB backup (safety net)
3. Deploy CrunchyDB PostgreSQL alongside existing MariaDB (both running temporarily)

### Migration using pgloader:
1. Deploy a temporary pod with pgloader installed:
   ```bash
   oc run pgloader --image=ghcr.io/dimitri/pgloader:latest --restart=Never -- sleep 3600
   ```
2. Create a pgloader configuration file:
   ```
   LOAD DATABASE
     FROM mysql://moodle:PASSWORD@mariadb-galera:3306/moodle
     INTO postgresql://moodle:PASSWORD@moodle-postgres-primary:5432/moodle

   WITH include drop, create tables, create indexes, reset sequences,
        workers = 4, concurrency = 2

   SET PostgreSQL PARAMETERS
     maintenance_work_mem to '512MB',
     work_mem to '64MB'

   CAST type varchar to text drop typemod;
   ```
3. Execute: `oc exec pgloader -- pgloader /path/to/config.load`
4. Validate row counts match between MariaDB and PostgreSQL
5. Run Moodle's database integrity check: `php admin/cli/check_database_schema.php`

### Post-migration steps:
1. Update Moodle config to point to PostgreSQL
2. Run `php admin/cli/upgrade.php` to ensure schema is correct
3. Take Moodle out of maintenance mode
4. Verify site functionality (login, course access, cron runs)
5. Once validated, decommission MariaDB Galera in dev

### Repeat for test and prod:
- After dev is stable for a reasonable period, repeat the migration process for `950003-test`
- After test validation, repeat for `950003-prod`

---

## Step 9: Cleanup MariaDB Artifacts (post-migration)

Once all three namespaces are running on PostgreSQL:

1. Remove MySQL PHP extensions from all Dockerfiles (`pdo_mysql`, `mysqli`)
2. Delete all files listed in Step 3 "Files to delete"
3. Remove `MARIADB_*` and `MYSQL_*` variables from `example.env`
4. Remove MariaDB Helm release: `helm uninstall mariadb-galera`
5. Delete MariaDB PVCs: `oc delete pvc data-mariadb-galera-0` (etc.)
6. Remove the separate backup-storage Helm deployment
7. Delete `docker-phpmyadmin.yml`

---

## Files Summary

### New files to create:
| File | Purpose |
|------|---------|
| `config/postgres/crunchy-values.yaml` | CrunchyDB Helm values |
| `openshift/scripts/deploy-crunchy-postgres.sh` | PostgreSQL deployment script |

### Files to modify:
| File | Change |
|------|--------|
| `PHP.Dockerfile` | Add `pdo_pgsql`, `pgsql` extensions |
| `Moodle.Dockerfile` | Add `pdo_pgsql`, `pgsql` extensions |
| `CRON.Dockerfile` | Add `pdo_pgsql`, `pgsql` extensions |
| `config/moodle/remote.config.php` | `dbtype` → `pgsql`, port → 5432 |
| `config/moodle/local.config.php` | `dbtype` → `pgsql`, port → 5432 |
| `config/cron/remote.config.php` | `dbtype` → `pgsql`, port → 5432 |
| `openshift/scripts/utils/database.sh` | Rewrite for PostgreSQL/Patroni |
| `example.env` | Update DB_HOST, DB_PORT, remove MARIADB vars |
| `example.versions.env` | Remove MARIADB_IMAGE, add Crunchy chart version |
| `.github/workflows/build.yml` | Remove MariaDB image build references |
| `.github/workflows/deploy.yml` | Call new deploy script, update inputs |
| `.github/workflows/helm-images.yml` | Remove MariaDB from image cache list |
| `openshift/template.json` | Update secrets and service references |
| `docker-common.yml` | Replace MariaDB with PostgreSQL service |
| `docker-compose.yml` | Update db-0 for PostgreSQL |
| `openshift/scripts/deploy-database-backups.sh` | Simplify or remove (pgBackRest replaces) |

### Files to delete (after full migration):
| File | Reason |
|------|--------|
| `openshift/scripts/deploy-mariadb-galera.sh` | Replaced by deploy-crunchy-postgres.sh |
| `openshift/scripts/mariadb-prestop.sh` | Galera-specific, not needed |
| `config/mariadb/` (entire directory) | All MariaDB config |
| `openshift/mariadb-galera.yml` | Galera Helm overrides |
| `openshift/mariadb.yml` | MariaDB operator manifest |
| `docker-phpmyadmin.yml` | Replace with pgAdmin |

---

## Verification Plan

### Local development:
1. `docker compose down -v` (clean volumes)
2. `docker compose up db-0 php-0 web-0` — verify Moodle installs on PostgreSQL
3. Login, create a test course, upload content, run cron — verify basic functionality

### Dev namespace (950003-dev):
1. Deploy CrunchyDB via Helm chart and verify `PostgresCluster` CR is ready
2. Verify pgBouncer service is routing connections
3. Run pgloader migration from existing MariaDB
4. Validate row counts: `SELECT schemaname, relname, n_live_tup FROM pg_stat_user_tables ORDER BY n_live_tup DESC;`
5. Run `php admin/cli/check_database_schema.php` — should report no issues
6. Run `php admin/cli/upgrade.php` — should complete cleanly
7. Access site, test login, course access, SCORM content, H5P
8. Verify cron job runs successfully
9. Monitor for 1-2 weeks before proceeding to test

### CI/CD pipeline:
1. Push to `950003-dev` branch
2. Verify `helm-images` job no longer tries to cache MariaDB image
3. Verify `deploy-crunchy-postgres.sh` runs successfully
4. Verify Moodle upgrade job completes
5. Verify Lighthouse audit passes

### Backup verification:
1. `oc exec moodle-postgres-repo-host-0 -- pgbackrest info` — verify backups are running
2. Test point-in-time recovery in dev namespace

---

## Risk Mitigation

1. **Data loss**: Full MariaDB backup taken before migration. MariaDB stays running alongside PostgreSQL until validation complete.
2. **Plugin compatibility**: All Moodle plugins used (psaelmsync, pathcurator, course_search, githubsync, hvp, report_allbackups) use Moodle's database abstraction layer (XMLDB) — they are database-engine agnostic.
3. **Performance regression**: PostgreSQL connection pooling via pgBouncer (included with CrunchyDB) mitigates connection overhead. Monitor slow query log (`log_min_duration_statement: 5000ms`).
4. **Rollback**: During transition, both databases exist. Rollback = revert config files to `dbtype = 'mariadb'` and redeploy.
5. **Character encoding**: pgloader handles `utf8mb4` → PostgreSQL `UTF8` conversion. Validate with `SELECT * FROM pg_database WHERE datname = 'moodle';` checking encoding is `UTF8`.
