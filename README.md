# Moodle for OpenShift / Docker

## Explanation

This directory contains the docker setup to run an instance of Moodle (MOODLE_405_STABLE). A number of containers are created as follows

* PHP 8.1-fpm to run the web instance of Moodle
* PHP 8.1-cli (second instance) to run cron
* Nginx as the web server
* Redis 8.0 for session and application cache
* MariaDB Galera 10.6 for database

All image versions are centrally managed in `example.versions.env`.
Most relevant runtime variables can be found in `example.env`.

## 🔄 Centralized Dependency Management

This repository uses centralized dependency management:

- **Source**: All versions are managed in `example.versions.env`
- **Generated**: Dependency files are auto-generated during CI/CD builds
- **Not Committed**: Generated files are excluded from git (see `.gitignore`)

For local development, generate fresh dependency files:
```bash
./openshift/scripts/populate-dependency-manifests.sh
docker-compose --env-file .env.generated up
```

📖 **See [.docs/centralized-dependency-management.md](.docs/centralized-dependency-management.md) for complete details**
📊 **Architecture Diagrams**: [.docs/diagrams/version-management-architecture.md](.docs/diagrams/version-management-architecture.md)

---

## �️ Local Development Scripts

**Windows developers:** See [scripts/README.md](scripts/README.md) for comprehensive local development tooling:

* **Version Validation** - Check version consistency before committing
* **Security Scanning** - Docker Scout integration for local vulnerability scanning
* **Pre-commit Hooks** - Automated validation workflows

Quick start:

```powershell
# Validate version consistency
.\scripts\local-validate-version-consistency.ps1

# Scan Docker images for vulnerabilities
.\scripts\local-dev-security-scan.ps1 -ImageName "moodle-php:latest"
```

---

## 🔒 Security

This project implements comprehensive security scanning and vulnerability management:

* **[Security Scanning Guide](.docs/security-scanning.md)** - Quick reference and configuration
* **[Vulnerability Exception Management](.docs/vulnerability-exceptions.md)** - TuxCare integration and exception handling
* **[Security Best Practices](.docs/security-scanning-best-practices.md)** - Strategic workflow design
* **[Dependency Management](.docs/centralized-dependency-management.md)** - Two-tier version control architecture
* **[Version Management Architecture](.docs/diagrams/version-management-architecture.md)** - Visual architecture guide

Security scanning runs automatically on every build with environment-specific settings (dev/test/prod).

## 📦 Infrastructure Management

### Persistent Volume Capacity Management

Automated PVC expansion for StatefulSets addresses Kubernetes limitations with storage resizing:

* **[PVC Expansion Guide](docs/pvc-expansion-guide.md)** - Comprehensive guide to automatic PVC expansion
* **CSV-Driven Sizing** - Centralized capacity configuration per environment
* **Safe Expansion** - Automated expansion during scale-down (replicas=0)
* **Deployment Integration** - Built into MariaDB Galera and right-sizing workflows

Key features:
- ✅ Automatic expansion based on CSV configuration
- ✅ Never shrinks PVCs (Kubernetes safety)
- ✅ StorageClass validation before expansion
- ✅ Wait for completion with timeout handling
- ✅ Expands while StatefulSet scaled to 0 (safe timing)

## Configuration

The main configuration is setup in the file docker-compose.yml. Each service is a container and the compose file gives the various configuration details for that service. The volumes directives map paths inside the containers to local paths. Note that local paths are relative to the directory with the compose file. There are no absolute paths.

PHP is slightly more complicated. The default PHP image doesn't have all the extensions we need. We therefore have a
PHP.Dockerfile referenced by the compose file. This tells docker to build a new image using these instructions. As PHP
sits on a very limited Debian Linux instance most of this such be fairly obvious. Note that the confiuration files (e.g php.ini) are in the local folder and copied there on the build.

The Moodle program and data files are mapped to local directories under this folder so you can access them as normal
without worrying about the containers.

Network host names are the same as the service names (e.g. just 'redis')

## 🛠️ Local Development Security Scanning

For Windows/Docker Desktop developers, **Docker Scout** provides an excellent GUI-based security scanning experience:

### Quick Start with Docker Scout

```powershell
# Check if Docker Scout is available
docker scout version

# Scan a built image
docker scout cves moodle:local

# Scan with detailed recommendations
docker scout recommendations moodle:local

# View results in Docker Desktop GUI
# Docker Desktop > Images > [Your Image] > View in Scout
```

### Docker Scout Benefits (Local Development)

* ✅ **Visual Interface**: Built into Docker Desktop
* ✅ **Real-time Analysis**: Scans as you build
* ✅ **Remediation Guidance**: Specific fix recommendations
* ✅ **Windows-Friendly**: Native Windows integration
* ✅ **Policy Compliance**: Custom security policies

### Automated Scanning (PowerShell)

For automated local security validation, see: `scripts/local-dev-security-scan.ps1`

**Note**: CI/CD pipelines use **Trivy** (not Docker Scout) for consistency with OpenShift environments.

---

## Set up

* Install Docker daemon and get running
* Stop any local instances of web server and mysql
* Make sure you have the docker-compose command installed
* Clone this repo somewhere suitable (everything else is relative to this folder)
* Creat subdirectories app/moodledata app/public.
* Clone/copy Moodle into app/public (not as a subdir, public itself)
* Copy config.php from here to that directory - modify as required
* app/moodledata should be chmod 0777
* docker-compose up --build -d
* You should then be able to access/install Moodle at <http://localhost:8080>

## Build / Run Moodle

docker-compose build --no-cache
docker-compose -p moodle up -d --env-file ./example.env

## 🚀 Build & Deployment

Deployment to OpenShift is handled via automated GitHub Actions workflows with comprehensive security scanning and health monitoring.

**📊 [View Complete Build & Deployment Flow Diagram](.docs/diagrams/build-deployment-flow.md)** - Interactive workflow visualization

### Key Workflows

| Workflow | Purpose | Trigger |
|----------|---------|---------|
| [**build.yml**](.github/workflows/build.yml) | Main CI/CD pipeline — env check, security scan, builds, deploy, Lighthouse monitor, notify | Push / PR / Schedule / Manual |
| [**deploy.yml**](.github/workflows/deploy.yml) | OpenShift deployment orchestration | Called by build.yml |
| [**security-comprehensive.yml**](.github/workflows/security-comprehensive.yml) | Standalone security validation | Manual dispatch |
| [**notify.yml**](.github/workflows/notify.yml) | Rocket.Chat notifications | Called by build.yml |
| [**cleanup.yml**](.github/workflows/cleanup.yml) | Old deployment cleanup | Called by build.yml |

### Branch-Specific Behavior

* **950003-dev**: Fast iteration (~5-10 min) - Basic security, skip builds, warnings only
* **950003-test**: Full validation (~25-35 min) - Comprehensive security, full builds, blocks on High/Critical
* **950003-prod**: Production deploy (~30-40 min) - Maximum security, controlled deployment, blocks on Critical

See [Build & Deployment Flow](.docs/diagrams/build-deployment-flow.md) for complete architecture details.

## Test GitHub Actions deployment locally using Act

### Note: Act must be installed locally, or run in a container

act -s GITHUB_TOKEN="$(gh auth token)" --env-file example.env --secret-file example.secrets -W './.github/workflows/build-push-php-image.yml'
