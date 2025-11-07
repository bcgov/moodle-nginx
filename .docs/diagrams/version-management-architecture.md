# Version Management Architecture

## 🏗️ Two-Tier System Overview

```mermaid
graph TB
    subgraph "🏗️ TIER 1: Infrastructure Versions"
        ENV[example.versions.env<br/>📋 Single Source of Truth]

        ENV --> PHP[PHP_IMAGE=bitnami/php-fpm:8.1.31<br/>PHP_VERSION=8.1]
        ENV --> NODE[NODE_VERSION=22.19.1<br/>NODE_IMAGE=node:22-alpine]
        ENV --> NGINX[NGINX_IMAGE=nginx:1.25.5]
        ENV --> DB[MARIADB_IMAGE=bitnami/mariadb:11.5.2]
        ENV --> REDIS[REDIS_IMAGE=redis:7.2.6]
    end

    subgraph "📦 TIER 2: Application Dependencies"
        COMPOSER[config/moodle/composer.json<br/>🐘 PHP Dependencies]
        NPM[config/lighthouse/package.json<br/>📦 NPM Dependencies]

        COMPOSER --> PHPLIBS["maennchen/zipstream-php: ^3.2.0<br/>+ other PHP libraries"]
        COMPOSER --> PHPCONSTRAINT["php: >=8.1<br/>platform.php: 8.1.31"]

        NPM --> NPMLIBS["lighthouse: ^13.0.1<br/>puppeteer: ^24.15.0"]
        NPM --> NODECONSTRAINT["engines.node: >=22.0.0"]
    end

    subgraph "🔄 Validation Layer"
        VALIDATE[validate-version-consistency.sh<br/>🛡️ Automated Compatibility Checks]
    end

    PHP -.-> |must satisfy| PHPCONSTRAINT
    NODE -.-> |must satisfy| NODECONSTRAINT

    VALIDATE --> |validates| PHP
    VALIDATE --> |validates| PHPCONSTRAINT
    VALIDATE --> |validates| NODE
    VALIDATE --> |validates| NODECONSTRAINT

    style ENV fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style COMPOSER fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style NPM fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style VALIDATE fill:#f1f8e9,stroke:#558b2f,stroke-width:2px
```

---

## 📊 Version Update Workflows

### Scenario A: Application Dependency Update

```mermaid
sequenceDiagram
    participant DEV as Developer
    participant COMPOSER as composer.json
    participant DEPENDABOT as Dependabot
    participant CI as CI/CD
    participant VALIDATE as Validation Script

    DEPENDABOT->>COMPOSER: Detects security update<br/>zipstream-php: ^3.2.0 → ^3.2.5
    DEPENDABOT->>DEV: Creates PR
    DEV->>COMPOSER: Reviews and merges
    CI->>VALIDATE: Runs validation
    VALIDATE->>VALIDATE: Checks: PHP 8.1 >= 8.1 ✅
    VALIDATE->>CI: Reports: COMPATIBLE
    CI->>CI: Deploys

    Note over DEV,VALIDATE: No infrastructure changes needed!<br/>Application updates are independent.
```

### Scenario B: Major Infrastructure Upgrade

```mermaid
sequenceDiagram
    participant DEVOPS as DevOps
    participant ENV as example.versions.env
    participant COMPOSER as composer.json
    participant VALIDATE as Validation Script
    participant CI as CI/CD

    DEVOPS->>ENV: Updates PHP_IMAGE to 8.3.0
    DEVOPS->>VALIDATE: Runs validation
    VALIDATE->>VALIDATE: Checks: PHP 8.3 >= 8.1 ✅
    VALIDATE-->>DEVOPS: ⚠️ Consider updating constraint
    DEVOPS->>COMPOSER: Updates "php": ">=8.3"
    DEVOPS->>COMPOSER: Tests: composer update
    COMPOSER-->>DEVOPS: All packages compatible ✅
    DEVOPS->>VALIDATE: Re-validates
    VALIDATE->>VALIDATE: Checks: PHP 8.3 >= 8.3 ✅
    VALIDATE-->>DEVOPS: COMPATIBLE
    DEVOPS->>CI: Commits ENV + COMPOSER together
    CI->>CI: Deploys new infrastructure

    Note over DEVOPS,CI: Infrastructure and application<br/>updated together atomically
```

### Scenario C: Version Mismatch Detection

```mermaid
sequenceDiagram
    participant DEV as Developer
    participant COMPOSER as composer.json
    participant ENV as example.versions.env
    participant VALIDATE as Validation Script
    participant CI as CI/CD

    DEV->>COMPOSER: Updates "php": ">=8.3"
    DEV->>CI: Commits change
    CI->>VALIDATE: Runs validation
    VALIDATE->>ENV: Reads: PHP_VERSION=8.1
    VALIDATE->>COMPOSER: Reads: "php": ">=8.3"
    VALIDATE->>VALIDATE: Checks: 8.1 >= 8.3 ❌
    VALIDATE-->>CI: ❌ INCOMPATIBLE<br/>Infrastructure: 8.1<br/>Application requires: 8.3
    CI-->>DEV: Build fails with error
    DEV->>ENV: Updates PHP_IMAGE to 8.3.0
    DEV->>CI: Re-commits
    CI->>VALIDATE: Re-validates
    VALIDATE-->>CI: ✅ COMPATIBLE
    CI->>CI: Deploys successfully

    Note over DEV,CI: Validation prevents deployment<br/>of incompatible versions
```

---

## 🔄 Dependency Management Comparison

### ❌ Fully Centralized (Problematic)

```mermaid
graph LR
    ENV[example.versions.env<br/>ALL VERSIONS]
    SCRIPT[Generation Script]
    COMPOSER[composer.json<br/>GENERATED]
    NPM[package.json<br/>GENERATED]

    ENV --> SCRIPT
    SCRIPT --> |generates| COMPOSER
    SCRIPT --> |generates| NPM

    COMPOSER -.->|breaks| TOOLS[Composer/Dependabot/IDE]
    NPM -.->|breaks| NPMTOOLS[NPM/Dependabot/IDE]

    style COMPOSER fill:#ffebee,stroke:#c62828,stroke-width:2px
    style NPM fill:#ffebee,stroke:#c62828,stroke-width:2px
    style TOOLS fill:#ffebee,stroke:#c62828
    style NPMTOOLS fill:#ffebee,stroke:#c62828
```

**Problems:**

- 🚫 Breaks `composer update` and `npm update`
- 🚫 Dependabot can't understand env files
- 🚫 IDE/tooling integration fails
- 🚫 Can't use semantic versioning (`^`, `~`)
- 🚫 Team must learn custom system

### ✅ Two-Tier Architecture (Optimal)

```mermaid
graph TB
    subgraph "Infrastructure Control"
        ENV[example.versions.env<br/>PHP_IMAGE, NODE_VERSION, etc.]
    end

    subgraph "Application Control"
        COMPOSER[composer.json<br/>Native Composer]
        NPM[package.json<br/>Native NPM]
    end

    subgraph "Ecosystem Tools"
        COMPOSERTOOLS[Composer Update<br/>Dependabot<br/>IDE Support]
        NPMTOOLS[NPM Update<br/>Dependabot<br/>IDE Support]
    end

    VALIDATE[validate-version-consistency.sh<br/>Automated Compatibility Validation]

    ENV -.->|must satisfy| COMPOSER
    ENV -.->|must satisfy| NPM

    COMPOSER --> COMPOSERTOOLS
    NPM --> NPMTOOLS

    VALIDATE --> |validates| ENV
    VALIDATE --> |validates| COMPOSER
    VALIDATE --> |validates| NPM

    style ENV fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style COMPOSER fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
    style NPM fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
    style VALIDATE fill:#fff9c4,stroke:#f9a825,stroke-width:2px
    style COMPOSERTOOLS fill:#c8e6c9,stroke:#2e7d32
    style NPMTOOLS fill:#c8e6c9,stroke:#2e7d32
```

**Benefits:**

- ✅ Standard tooling works natively
- ✅ Dependabot monitors both files
- ✅ Semantic versioning preserved
- ✅ Team uses familiar workflows
- ✅ Automated validation ensures compatibility

---

## 🎯 Decision Tree: Which File to Update?

```mermaid
graph TD
    START{What are you updating?}

    START -->|Docker base image| ENV[Update example.versions.env<br/>🏗️ Infrastructure change]
    START -->|System package version| ENV
    START -->|PHP runtime version| ENV
    START -->|Node runtime version| ENV
    START -->|Database version| ENV
    START -->|Redis version| ENV

    START -->|PHP library| COMPOSER[Update composer.json<br/>📦 Application change]
    START -->|JavaScript tool| NPM[Update package.json<br/>📦 Application change]

    ENV --> VALIDATE1{Run validation}
    COMPOSER --> VALIDATE2{Run validation}
    NPM --> VALIDATE3{Run validation}

    VALIDATE1 --> RESULT1{Compatible?}
    VALIDATE2 --> RESULT2{Compatible?}
    VALIDATE3 --> RESULT3{Compatible?}

    RESULT1 -->|Yes ✅| COMMIT1[Commit infrastructure change]
    RESULT1 -->|No ❌| FIXINFRA[Update app constraints<br/>in composer.json/package.json]

    RESULT2 -->|Yes ✅| COMMIT2[Commit application change]
    RESULT2 -->|No ❌| FIXAPP[Upgrade infrastructure<br/>in example.versions.env]

    RESULT3 -->|Yes ✅| COMMIT3[Commit application change]
    RESULT3 -->|No ❌| FIXAPP

    FIXINFRA --> REVALIDATE1[Re-run validation]
    FIXAPP --> REVALIDATE2[Re-run validation]

    REVALIDATE1 --> COMMITBOTH[Commit infrastructure + app together]
    REVALIDATE2 --> COMMITBOTH

    style START fill:#e1f5ff,stroke:#01579b,stroke-width:3px
    style ENV fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style COMPOSER fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style NPM fill:#fff3e0,stroke:#e65100,stroke-width:2px
    style COMMIT1 fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
    style COMMIT2 fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
    style COMMIT3 fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
    style COMMITBOTH fill:#c8e6c9,stroke:#2e7d32,stroke-width:2px
```

---

## 🛡️ Security & Validation Flow

```mermaid
graph TB
    subgraph "🔒 Security Scanning Layers"
        TRIVY[Trivy<br/>Base Image Vulnerabilities]
        COMPOSERAUDIT[Composer Audit<br/>PHP Dependency Vulnerabilities]
        NPMAUDIT[NPM Audit<br/>NPM Dependency Vulnerabilities]
        DEPENDABOT[Dependabot<br/>Real-time Security Advisories]
    end

    subgraph "🔄 Version Validation"
        VALIDATE[validate-version-consistency.sh<br/>Compatibility Checks]
    end

    subgraph "📦 Deployment Artifacts"
        DOCKER[Docker Images]
        APP[Application Code]
    end

    TRIVY --> |scans| DOCKER
    COMPOSERAUDIT --> |scans| APP
    NPMAUDIT --> |scans| APP
    DEPENDABOT --> |monitors| APP
    VALIDATE --> |validates| DOCKER
    VALIDATE --> |validates| APP

    DOCKER --> DEPLOY{All checks pass?}
    APP --> DEPLOY

    DEPLOY -->|Yes ✅| PROD[Deploy to Production]
    DEPLOY -->|No ❌| BLOCK[Block Deployment<br/>Report Issues]

    style TRIVY fill:#bbdefb,stroke:#1565c0
    style COMPOSERAUDIT fill:#bbdefb,stroke:#1565c0
    style NPMAUDIT fill:#bbdefb,stroke:#1565c0
    style DEPENDABOT fill:#bbdefb,stroke:#1565c0
    style VALIDATE fill:#fff9c4,stroke:#f9a825,stroke-width:2px
    style PROD fill:#c8e6c9,stroke:#2e7d32,stroke-width:3px
    style BLOCK fill:#ffcdd2,stroke:#c62828,stroke-width:3px
```

---

## 📋 Summary Table

| Aspect | Infrastructure (Tier 1) | Application (Tier 2) |
|--------|------------------------|----------------------|
| **File** | `example.versions.env` | `composer.json`, `package.json` |
| **Purpose** | Runtime environments | Installed libraries/tools |
| **Examples** | PHP 8.1, Node 22, Nginx 1.25 | zipstream-php, Lighthouse |
| **Update Frequency** | Quarterly / Major releases | Monthly / Security patches |
| **Versioning** | Exact versions (`8.1.31`) | Semantic ranges (`^3.2.0`) |
| **Managed By** | DevOps team | Development team |
| **Tools** | Docker, OpenShift | Composer, NPM, Dependabot |
| **Validation** | `validate-version-consistency.sh` | Native tool validation + compatibility check |
| **CI/CD Integration** | Image builds | Dependency installation |
| **Lock Files** | N/A (exact versions) | `composer.lock`, `package-lock.json` |

---

## 🎓 Key Principles

1. **Separation of Concerns**: Infrastructure stability vs application flexibility
2. **Tool-Native**: Use ecosystem tools for what they're designed for
3. **Automated Validation**: Catch incompatibilities early in CI/CD
4. **Atomic Updates**: Major upgrades commit infrastructure + application together
5. **Security Layers**: Multi-tool scanning at all dependency levels

---

*This architecture recognizes that **not all versions should be centralized.** Different types of dependencies have different lifecycles, tooling, and update patterns. The two-tier approach provides the right balance of control and flexibility.*
