# 🔒 Security Scanning Flow Diagram

## Complete Security Scanning Architecture

```mermaid
graph TD
    Start([GitHub Action Triggered]) --> CheckEnv[🔍 checkEnv Job]

    CheckEnv --> Config[📋 Read Security Config<br/>SCAN_LEVEL, EXIT_ON, etc.]
    Config --> Enabled{SCAN_ENABLED<br/>= YES?}

    Enabled -->|NO| SkipScan[⏭️ Skip All Security Scans]
    SkipScan --> Build

    Enabled -->|YES| Level{SCAN_LEVEL?}

    Level -->|OFF| SkipScan
    Level -->|MINIMAL| Phase1Min[🔒 Phase 1: MINIMAL<br/>~1 min<br/>- CVE Advisories Only<br/>- Critical Composer Issues]
    Level -->|BASIC| Phase1Basic[🔒 Phase 1: BASIC<br/>~3 min<br/>- CVE Advisories<br/>- Composer Audit<br/>- System Packages<br/>- Git Dependencies]
    Level -->|FULL| Phase1Full[🔒 Phase 1: FULL<br/>~5 min<br/>- Everything in BASIC<br/>- Container Scanning<br/>- License Compliance]

    Phase1Min --> Exit1{EXIT_ON<br/>Strategy}
    Phase1Basic --> Exit1
    Phase1Full --> Exit1

    Exit1 -->|WARN| Build[🔨 Build Images]
    Exit1 -->|CRITICAL| Critical1{Critical<br/>Found?}
    Exit1 -->|HIGH| High1{High/Critical<br/>Found?}
    Exit1 -->|MEDIUM| Medium1{Med/High/Crit<br/>Found?}
    Exit1 -->|ANY| Any1{Any Vulns<br/>Found?}

    Critical1 -->|YES| Fail1[❌ FAIL BUILD<br/>Exit Code 2]
    Critical1 -->|NO| Build
    High1 -->|YES| Fail1
    High1 -->|NO| Build
    Medium1 -->|YES| Fail1
    Medium1 -->|NO| Build
    Any1 -->|YES| Fail1
    Any1 -->|NO| Build

    Build --> Docker[🐳 Build Docker Images<br/>- Moodle<br/>- PHP<br/>- Web<br/>- Cron<br/>- Redis Proxy]

    Docker --> Phase2[🔒 Phase 2: Post-Build<br/>~3-5 min<br/>- Scan Built Images<br/>- BEFORE Artifactory Push]

    Phase2 --> Exit2{EXIT_ON<br/>Strategy}

    Exit2 -->|WARN| Push[📤 Push to Artifactory]
    Exit2 -->|CRITICAL| Critical2{Critical<br/>in Images?}
    Exit2 -->|HIGH| High2{High/Critical<br/>in Images?}
    Exit2 -->|MEDIUM| Medium2{Med+<br/>in Images?}
    Exit2 -->|ANY| Any2{Any Vulns<br/>in Images?}

    Critical2 -->|YES| Fail2[❌ FAIL BUILD<br/>Don't Push to Registry]
    Critical2 -->|NO| Push
    High2 -->|YES| Fail2
    High2 -->|NO| Push
    Medium2 -->|YES| Fail2
    Medium2 -->|NO| Push
    Any2 -->|YES| Fail2
    Any2 -->|NO| Push

    Push --> Deploy[🚀 Deploy to OpenShift]

    Deploy --> Phase3[🔒 Phase 3: Post-Deploy<br/>~5 min<br/>ALWAYS WARN ONLY]

    Phase3 --> NPM[🔍 NPM Audit FIRST<br/>Supply Chain Protection<br/>Check Lighthouse Packages]

    NPM --> NPMVuln{NPM Vulns<br/>Found?}

    NPMVuln -->|YES| NPMWarn[⚠️ WARN: Lighthouse May Use<br/>Compromised Packages]
    NPMVuln -->|NO| NPMSafe[✅ NPM Dependencies Validated]

    NPMWarn --> Lighthouse
    NPMSafe --> Lighthouse[🚦 Run Lighthouse Audit<br/>Performance & Security]

    Lighthouse --> Phase3Exit[⚠️ WARN Only<br/>Never Fail<br/>Already Deployed]

    Phase3Exit --> Report[📊 Generate Security Report<br/>Upload Artifacts]

    Report --> Complete([✅ Security Scanning Complete])

    Fail1 --> Notify[🔔 Notify Team<br/>Security Issues Found]
    Fail2 --> Notify

    style Phase1Min fill:#fff3cd
    style Phase1Basic fill:#d1ecf1
    style Phase1Full fill:#d4edda
    style Phase2 fill:#d4edda
    style Phase3 fill:#f8d7da
    style Fail1 fill:#f8d7da,color:#721c24
    style Fail2 fill:#f8d7da,color:#721c24
    style NPMWarn fill:#fff3cd
    style NPMSafe fill:#d4edda
```

---

## Configuration Impact Flow

```mermaid
graph LR
    subgraph Environment Variables
        ENABLED[SECURITY_SCAN_ENABLED]
        LEVEL[SECURITY_SCAN_LEVEL]
        EXIT[SECURITY_SCAN_EXIT_ON]
        CONTAINERS[SECURITY_SCAN_CONTAINERS]
        CACHE[SECURITY_SCAN_CACHE]
    end

    subgraph "Dev Environment"
        DevConfig["LEVEL: BASIC<br/>EXIT: WARN<br/>CONTAINERS: NO"]
        DevResult["⚡ ~2-3 min<br/>🟢 Core scan warn-only<br/>⚠️ Preflight may fail unresolved High/Critical"]
    end

    subgraph "Test Environment"
        TestConfig["LEVEL: FULL<br/>EXIT: HIGH<br/>CONTAINERS: YES"]
        TestResult["⏱️ ~6-8 min<br/>🟡 Blocks High/Critical<br/>🛡️ Comprehensive"]
    end

    subgraph "Prod Environment"
        ProdConfig["LEVEL: FULL<br/>EXIT: CRITICAL<br/>CONTAINERS: YES"]
        ProdResult["⏱️ ~6-8 min<br/>🔴 Blocks Critical Only<br/>🛡️ Maximum Security"]
    end

    LEVEL --> DevConfig
    EXIT --> DevConfig
    CONTAINERS --> DevConfig

    LEVEL --> TestConfig
    EXIT --> TestConfig
    CONTAINERS --> TestConfig

    LEVEL --> ProdConfig
    EXIT --> ProdConfig
    CONTAINERS --> ProdConfig

    DevConfig --> DevResult
    TestConfig --> TestResult
    ProdConfig --> ProdResult

    style DevResult fill:#d4edda
    style TestResult fill:#fff3cd
    style ProdResult fill:#f8d7da
```

---

## Security Scanning Decision Tree

```mermaid
graph TD
    Start([Security Scan Triggered]) --> Q1{Environment?}

    Q1 -->|Dev| DevPath[BASIC + WARN + NO Containers]
    Q1 -->|Test| TestPath[FULL + HIGH + YES Containers]
    Q1 -->|Prod| ProdPath[FULL + CRITICAL + YES Containers]
    Q1 -->|Hotfix| HotfixPath[OFF / MINIMAL + WARN]

    DevPath --> DevScan[🔍 Scan: ~3 min]
    TestPath --> TestScan[🔍 Scan: ~8 min]
    ProdPath --> ProdScan[🔍 Scan: ~8 min]
    HotfixPath --> HotfixScan[🔍 Scan: 0-1 min]

    DevScan --> DevVuln{Vulnerabilities?}
    TestScan --> TestVuln{High/Critical?}
    ProdScan --> ProdVuln{Critical?}
    HotfixScan --> HotfixVuln{Critical?}

    DevVuln -->|YES| DevWarn[⚠️ WARN: Continue Build]
    DevVuln -->|NO| DevPass[✅ PASS: Continue Build]

    TestVuln -->|YES| TestFail[❌ FAIL: Block Build]
    TestVuln -->|NO| TestPass[✅ PASS: Continue Build]

    ProdVuln -->|YES| ProdFail[❌ FAIL: Block Build]
    ProdVuln -->|NO| ProdPass[✅ PASS: Continue Build]

    HotfixVuln -->|YES| HotfixWarn[⚠️ WARN: Continue Anyway<br/>Emergency Deploy]
    HotfixVuln -->|NO| HotfixPass[✅ PASS: Continue Build]

    DevWarn --> Build
    DevPass --> Build
    TestPass --> Build
    ProdPass --> Build
    HotfixWarn --> Build
    HotfixPass --> Build

    TestFail --> Notify[🔔 Notify Team<br/>Fix Required]
    ProdFail --> Notify

    Build[Continue to Build Phase]

    style DevWarn fill:#fff3cd
    style DevPass fill:#d4edda
    style TestFail fill:#f8d7da,color:#721c24
    style TestPass fill:#d4edda
    style ProdFail fill:#f8d7da,color:#721c24
    style ProdPass fill:#d4edda
    style HotfixWarn fill:#fff3cd
```

---

## Phase 3: NPM-First Security Flow

**CRITICAL**: NPM audit BEFORE Lighthouse execution to prevent supply chain attacks

```mermaid
sequenceDiagram
    participant GH as GitHub Actions
    participant NPM as NPM Audit
    participant LH as Lighthouse CI
    participant App as Deployed Application

    GH->>NPM: 1. Audit config/lighthouse/package.json

    alt NPM Vulnerabilities Found
        NPM-->>GH: ⚠️ Critical/High vulnerabilities detected
        GH->>GH: Log WARNING (don't fail, already deployed)
        GH->>LH: ⚠️ Proceed with caution
        Note over GH,LH: Lighthouse may use<br/>compromised packages
    else No NPM Vulnerabilities
        NPM-->>GH: ✅ Dependencies validated
        GH->>LH: ✅ Safe to run Lighthouse
    end

    LH->>App: 2. Run performance audit
    LH->>App: 3. Run security header checks
    LH->>App: 4. Run accessibility tests

    App-->>LH: Results
    LH-->>GH: Report uploaded

    Note over GH: ❌ DO NOT re-scan containers<br/>❌ DO NOT re-scan Composer<br/>✅ ONLY app runtime security
```

---

## Vulnerability Severity Exit Strategy

```mermaid
graph TD
    Vuln[Vulnerabilities Detected] --> Parse[Parse Severity Counts<br/>Critical, High, Medium, Low]

    Parse --> Strategy{EXIT_ON<br/>Strategy?}

    Strategy -->|WARN| WarnPath[🟢 Always Continue<br/>Report Only]
    Strategy -->|CRITICAL| CritPath{Critical > 0?}
    Strategy -->|HIGH| HighPath{Critical OR<br/>High > 0?}
    Strategy -->|MEDIUM| MedPath{Critical OR High<br/>OR Medium > 0?}
    Strategy -->|ANY| AnyPath{Any Vuln > 0?}

    CritPath -->|YES| Fail[❌ Exit Code 2<br/>BLOCK BUILD]
    CritPath -->|NO| Pass[✅ Exit Code 0<br/>CONTINUE]

    HighPath -->|YES| Fail
    HighPath -->|NO| Pass

    MedPath -->|YES| Fail
    MedPath -->|NO| Pass

    AnyPath -->|YES| Fail
    AnyPath -->|NO| Pass

    WarnPath --> Report[📊 Generate Report]
    Pass --> Report
    Fail --> Notify[🔔 Notify Team<br/>Security Gate Failed]

    Report --> Continue([Continue Workflow])
    Notify --> Stop([❌ Workflow Stopped])

    style Fail fill:#f8d7da,color:#721c24
    style Pass fill:#d4edda
    style WarnPath fill:#fff3cd
```

---

## Configuration Priority Matrix

| Priority | Configuration | Reason |
|----------|--------------|--------|
| 🔴 **CRITICAL** | `SECURITY_SCAN_ENABLED: "YES"` | Security scanning must be active |
| 🔴 **CRITICAL** | NPM audit BEFORE Lighthouse | Prevent supply chain attacks |
| 🟡 **HIGH** | `EXIT_ON` varies by environment | Balance security vs velocity |
| 🟡 **HIGH** | `SCAN_LEVEL: "FULL"` in prod | Comprehensive production validation |
| 🟢 **MEDIUM** | `SCAN_CONTAINERS: "NO"` in dev | Performance optimization |
| 🟢 **MEDIUM** | `SECURITY_SCAN_CACHE: "YES"` | Faster scans (30-60s savings) |
| 🔵 **LOW** | Scheduled deep scans | Weekly comprehensive audits |

---

## Summary

This flow diagram illustrates:

1. **Configuration-Driven**: Environment variables control all behavior
2. **Environment-Aware**: Different strategies for dev/test/prod
3. **Fail-Fast**: Critical issues caught in 2-3 minutes (Phase 1)
4. **Supply Chain Protection**: NPM audit BEFORE Lighthouse execution
5. **Non-Blocking Dev**: Warnings in dev, strict blocking in prod
6. **Performance Optimized**: Skip expensive scans in dev, enable in prod

**Key Insight**: Security scanning adapts to environment context while maintaining consistent protection.
