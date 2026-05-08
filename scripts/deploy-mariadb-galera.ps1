<#
.SYNOPSIS
    Deploy/upgrade MariaDB Galera StatefulSet via Helm

.DESCRIPTION
    Local equivalent of the CI/CD deployment in deploy-mariadb-galera.sh.
    Parses --set flags DIRECTLY from the .sh script to guarantee parity
    with GitHub Actions deployments. Variables are resolved from .env files
    and cluster secrets at runtime.

    ┌─────────────────────────────────────────────────────────────────┐
    │  SINGLE SOURCE OF TRUTH                                        │
    │                                                                │
    │  Helm --set flags are parsed from:                             │
    │    openshift/scripts/deploy-mariadb-galera.sh                  │
    │                                                                │
    │  Variables resolved from:                                      │
    │    .env / example.env         (DB_*, deployment names)         │
    │    example.versions.env       (images, Artifactory config)     │
    │    moodle-secrets (cluster)   (passwords)                      │
    │    Helm release values        (current state, for upgrades)    │
    │                                                                │
    │  No Helm flags are hardcoded in this script.                   │
    │  Edit the .sh → this .ps1 picks up the changes automatically. │
    └─────────────────────────────────────────────────────────────────┘

    Supports three modes:
    - Upgrade (default): helm upgrade --reuse-values (most common)
    - Install: helm install (first-ever deployment only)
    - ProbeOnly: patch probe timeouts on the live StatefulSet without Helm

.PARAMETER Namespace
    Target OpenShift namespace (e.g., 950003-test)

.PARAMETER Mode
    Deployment mode:
    - Upgrade:   helm upgrade --reuse-values (default, safe for running clusters)
    - Install:   helm install (first deployment only, creates db/user/passwords)
    - ProbeOnly: patch probe timeouts on the live StatefulSet without Helm

.PARAMETER Replicas
    Target replica count. Auto-detected from sizing CSV if not specified.

.PARAMETER DryRun
    Show Helm commands without executing (--dry-run --debug)

.PARAMETER SkipProbes
    Skip probe tuning (use chart defaults for probes)

.EXAMPLE
    # Standard upgrade (most common)
    .\scripts\deploy-mariadb-galera.ps1 -Namespace 950003-test

.EXAMPLE
    # Dry-run to preview what Helm will do
    .\scripts\deploy-mariadb-galera.ps1 -Namespace 950003-test -DryRun

.EXAMPLE
    # Tune probes only (no Helm upgrade)
    .\scripts\deploy-mariadb-galera.ps1 -Namespace 950003-test -Mode ProbeOnly

.EXAMPLE
    # Fresh install (first-ever deployment)
    .\scripts\deploy-mariadb-galera.ps1 -Namespace 950003-test -Mode Install

.NOTES
    Prerequisites:
    - helm CLI installed and in PATH
    - oc CLI logged into the target cluster
    - Target namespace accessible

    How --set parsing works:
    1. Reads openshift/scripts/deploy-mariadb-galera.sh
    2. Extracts the "helm install" block (most complete set of flags)
    3. Parses each "--set key=value" line
    4. Resolves bash variables ($VAR, ${VAR}, ${VAR:-default})
    5. For Upgrade: adds --reuse-values, flips bootstrap=false
    6. For Install: uses all flags as-is

    Related files:
    - CI/CD deploy: openshift/scripts/deploy-mariadb-galera.sh
    - Reference values: config/mariadb/galera-values.yaml (documentation)
    - Sizing: openshift/<namespace>-sizing.csv (replica count)
    - Versions: example.versions.env (image tags, Artifactory config)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Target OpenShift namespace")]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(HelpMessage = "Deployment mode")]
    [ValidateSet("Upgrade", "Install", "ProbeOnly")]
    [string]$Mode = "Upgrade",

    [Parameter(HelpMessage = "Target replica count (auto-detected from sizing CSV)")]
    [int]$Replicas = 0,

    [Parameter(HelpMessage = "Show Helm commands without executing")]
    [switch]$DryRun,

    [Parameter(HelpMessage = "Skip probe tuning")]
    [switch]$SkipProbes
)

$ErrorActionPreference = "Stop"

# =============================================================================
# CONFIGURATION
# =============================================================================
$ReleaseName = "mariadb-galera"
$ChartRef = "oci://registry-1.docker.io/bitnamicharts/mariadb-galera"
$repoRoot = Split-Path $PSScriptRoot -Parent
$deployScript = Join-Path $repoRoot "openshift/scripts/deploy-mariadb-galera.sh"

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  MARIADB GALERA DEPLOYMENT" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Namespace:  $Namespace" -ForegroundColor Gray
Write-Host "  Mode:       $Mode" -ForegroundColor Gray
Write-Host ""

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

<#
.SYNOPSIS
    Parse a bash env file (KEY=VALUE format), skipping comments and blanks.
    Returns a hashtable of variable name → value.
#>
function Read-EnvFile {
    param([string]$Path)
    $vars = @{}
    if (-not (Test-Path $Path)) { return $vars }
    foreach ($line in (Get-Content $Path)) {
        # Skip comments and blank lines
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        # Match: KEY=VALUE or KEY="VALUE" or KEY='VALUE' (strip inline comments)
        if ($line -match "^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*['""]?([^'""#]*)['""]?") {
            $vars[$Matches[1]] = $Matches[2].Trim()
        }
    }
    return $vars
}

<#
.SYNOPSIS
    Resolve a bash variable expression using an env hashtable.
    Handles: $VAR, ${VAR}, ${VAR:-default}, "${VAR}", literal values.
#>
function Resolve-BashVar {
    param([string]$Expr, [hashtable]$Env)

    $resolved = $Expr

    # Strip surrounding double quotes
    $resolved = $resolved -replace '^"(.*)"$', '$1'

    # Pattern: ${VAR:-default}
    while ($resolved -match '\$\{([A-Za-z_][A-Za-z0-9_]*):-([^}]*)\}') {
        $varName = $Matches[1]
        $default = $Matches[2]
        $value = if ($Env.ContainsKey($varName) -and $Env[$varName]) { $Env[$varName] } else { $default }
        $resolved = $resolved -replace [regex]::Escape($Matches[0]), $value
    }

    # Pattern: ${VAR}
    while ($resolved -match '\$\{([A-Za-z_][A-Za-z0-9_]*)\}') {
        $varName = $Matches[1]
        $value = if ($Env.ContainsKey($varName)) { $Env[$varName] } else { "" }
        $resolved = $resolved -replace [regex]::Escape($Matches[0]), $value
    }

    # Pattern: $VAR (at end of string or followed by non-alnum)
    while ($resolved -match '\$([A-Za-z_][A-Za-z0-9_]*)') {
        $varName = $Matches[1]
        $value = if ($Env.ContainsKey($varName)) { $Env[$varName] } else { "" }
        $resolved = $resolved -replace [regex]::Escape($Matches[0]), $value
    }

    return $resolved
}

<#
.SYNOPSIS
    Parse --set flags from a helm install/upgrade block in a bash script.
    Returns an ordered hashtable of key → raw_value (with $VARs unresolved).
#>
function Parse-HelmSets {
    param(
        [string]$ScriptPath,
        [string]$BlockType = "install"  # "install" or "upgrade"
    )

    $lines = Get-Content $ScriptPath
    $sets = [ordered]@{}
    $inBlock = $false
    $blockPattern = if ($BlockType -eq "install") {
        'helm install \$DB_DEPLOYMENT_NAME'
    } else {
        'helm upgrade \$DB_DEPLOYMENT_NAME'
    }

    foreach ($line in $lines) {
        # Detect block start
        if (-not $inBlock -and $line -match $blockPattern) {
            $inBlock = $true
            continue
        }

        if ($inBlock) {
            # Extract --set key=value
            if ($line -match '\s*--set\s+(\S+?)=(.+?)(?:\s*\\)?\s*$') {
                $key = $Matches[1].Trim()
                $value = $Matches[2].Trim().TrimEnd('\').Trim()
                $sets[$key] = $value
            }
            # Skip chart reference line and --reuse-values
            elseif ($line -match 'oci://' -or $line -match '--reuse-values') {
                continue
            }
            # End of block: non-continuation, non-set, non-chart line
            elseif ($sets.Count -gt 0 -and $line -notmatch '\\\s*$') {
                break
            }
        }
    }

    return $sets
}

# =============================================================================
# PREREQUISITES
# =============================================================================

# Verify oc login
$currentProject = oc project -q 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Not logged into OpenShift. Run 'oc login' first." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] OpenShift context: $currentProject" -ForegroundColor Green

# Verify helm (not needed for ProbeOnly)
if ($Mode -ne "ProbeOnly") {
    $helmVersion = helm version --short 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Helm CLI not found. Install Helm first." -ForegroundColor Red
        Write-Host "  winget install Helm.Helm" -ForegroundColor Gray
        exit 1
    }
    Write-Host "[OK] Helm: $helmVersion" -ForegroundColor Green
}

# Verify deploy script exists
if (-not (Test-Path $deployScript)) {
    Write-Host "[ERROR] Deploy script not found: $deployScript" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Source: openshift/scripts/deploy-mariadb-galera.sh" -ForegroundColor Green

# Switch to target namespace
oc project $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Cannot switch to namespace: $Namespace" -ForegroundColor Red
    exit 1
}

# =============================================================================
# LOAD ENVIRONMENT VARIABLES
# Build a resolution table from all .env sources + cluster secrets
# =============================================================================
Write-Host ""
Write-Host "[INFO] Loading environment variables..." -ForegroundColor Cyan

$envVars = @{}

# Layer 1: example.env (base defaults)
$envFile = Join-Path $repoRoot "example.env"
if (Test-Path $envFile) {
    $envVars += Read-EnvFile $envFile
    Write-Host "  Loaded: example.env ($($envVars.Count) vars)" -ForegroundColor DarkGray
}

# Layer 2: .env (local overrides, higher priority)
$dotEnvFile = Join-Path $repoRoot ".env"
if (Test-Path $dotEnvFile) {
    $localVars = Read-EnvFile $dotEnvFile
    foreach ($kv in $localVars.GetEnumerator()) {
        $envVars[$kv.Key] = $kv.Value
    }
    Write-Host "  Loaded: .env ($($localVars.Count) vars, local overrides)" -ForegroundColor DarkGray
}

# Layer 3: example.versions.env (image versions, Artifactory config)
$versionsFile = Join-Path $repoRoot "example.versions.env"
if (Test-Path $versionsFile) {
    $versionVars = Read-EnvFile $versionsFile
    foreach ($kv in $versionVars.GetEnumerator()) {
        $envVars[$kv.Key] = $kv.Value
    }
    Write-Host "  Loaded: example.versions.env ($($versionVars.Count) vars)" -ForegroundColor DarkGray
}

# Layer 4: Cluster secrets (highest priority for credentials)
try {
    $secretJson = oc get secret moodle-secrets -n $Namespace -o json 2>&1 | ConvertFrom-Json
    $envVars["DB_PASSWORD"] = [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String($secretJson.data.'database-password'))
    $envVars["DB_USER"] = [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String($secretJson.data.'database-user'))
    $envVars["DB_NAME"] = [System.Text.Encoding]::UTF8.GetString(
        [System.Convert]::FromBase64String($secretJson.data.'database-name'))
    Write-Host "  Loaded: moodle-secrets (cluster credentials)" -ForegroundColor DarkGray
} catch {
    Write-Host "[WARN] Could not read moodle-secrets" -ForegroundColor Yellow
    if ($Mode -eq "Install") {
        Write-Host "[ERROR] Install mode requires credentials. Create moodle-secrets first." -ForegroundColor Red
        exit 1
    }
}

# Layer 5: Compute RESOLVED_IMAGE_* (replicates helm-image-resolver.sh logic)
$mariadbImage = $envVars["MARIADB_IMAGE"]  # e.g., "bitnamilegacy/mariadb-galera:10.6"
$useArtifactory = $envVars["USE_ARTIFACTORY"]
$artifactoryRegistry = $envVars["ARTIFACTORY_REGISTRY"]

if ($mariadbImage -match '^(.+):(.+)$') {
    $imgRepo = $Matches[1]
    $imgTag = $Matches[2]

    if ($useArtifactory -eq "true" -and $artifactoryRegistry) {
        # Artifactory mode: registry baked into repository, empty registry field
        $envVars["RESOLVED_IMAGE_REGISTRY"] = ""
        $envVars["RESOLVED_IMAGE_REPOSITORY"] = "${artifactoryRegistry}/${imgRepo}"
        $envVars["RESOLVED_IMAGE_TAG"] = $imgTag
    } else {
        # Direct mode: use Helm repo
        $helmRepo = $envVars["HELM_REPO"]
        $envVars["RESOLVED_IMAGE_REGISTRY"] = if ($helmRepo) { $helmRepo } else { "docker.io" }
        $envVars["RESOLVED_IMAGE_REPOSITORY"] = $imgRepo
        $envVars["RESOLVED_IMAGE_TAG"] = $imgTag
    }

    $resolvedImage = "$($envVars['RESOLVED_IMAGE_REPOSITORY']):$($envVars['RESOLVED_IMAGE_TAG'])"
    Write-Host "  Image: $resolvedImage" -ForegroundColor DarkGray
} else {
    Write-Host "[ERROR] Cannot parse MARIADB_IMAGE: $mariadbImage" -ForegroundColor Red
    exit 1
}

# Override DEPLOY_NAMESPACE with the -Namespace parameter (matches CI/CD behavior)
$envVars["DEPLOY_NAMESPACE"] = $Namespace

# Layer 6: Helm release values (for upgrade, use current state as fallback)
$releaseExists = $false
$helmValues = $null
if ($Mode -ne "ProbeOnly") {
    try {
        $helmValuesRaw = helm get values $ReleaseName -n $Namespace -o json 2>&1
        if ($LASTEXITCODE -eq 0) {
            $helmValues = $helmValuesRaw | ConvertFrom-Json
            $releaseExists = $true
            Write-Host "  Helm release: found" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  Helm release: not found" -ForegroundColor Yellow
    }
}

# Replica count: sizing CSV > Helm release > env file > default
if ($Replicas -le 0) {
    $sizingCsv = Join-Path $repoRoot "openshift/${Namespace}-sizing.csv"
    if (Test-Path $sizingCsv) {
        foreach ($line in (Get-Content $sizingCsv)) {
            $fields = $line -split ','
            if ($fields[0].Trim() -eq $ReleaseName -and $fields.Count -ge 3 -and $fields[2].Trim() -gt 0) {
                $Replicas = [int]$fields[2].Trim()
                Write-Host "  Replicas: $Replicas (from $($Namespace)-sizing.csv)" -ForegroundColor DarkGray
                break
            }
        }
    }
    if ($Replicas -le 0 -and $helmValues -and $helmValues.replicaCount) {
        $Replicas = [int]$helmValues.replicaCount
        Write-Host "  Replicas: $Replicas (from Helm release)" -ForegroundColor DarkGray
    }
    if ($Replicas -le 0 -and $envVars["DB_REPLICAS"]) {
        $Replicas = [int]$envVars["DB_REPLICAS"]
        Write-Host "  Replicas: $Replicas (from env)" -ForegroundColor DarkGray
    }
    if ($Replicas -le 0) {
        $Replicas = 2
        Write-Host "  Replicas: $Replicas (default)" -ForegroundColor Yellow
    }
}
$envVars["DB_REPLICAS"] = "$Replicas"

# =============================================================================
# LIVE CLUSTER STATE
# =============================================================================
Write-Host ""
Write-Host "[INFO] Current cluster state:" -ForegroundColor Cyan

$stsExists = $false
try {
    $stsJson = oc get statefulset $ReleaseName -n $Namespace -o json 2>&1 | ConvertFrom-Json
    if ($LASTEXITCODE -eq 0) { $stsExists = $true }
} catch {}

if (-not $stsExists) {
    if ($Mode -ne "Install") {
        Write-Host "[ERROR] StatefulSet not found. Use -Mode Install for first deployment." -ForegroundColor Red
        exit 1
    }
    Write-Host "  StatefulSet: not found (fresh install)" -ForegroundColor Yellow
} else {
    $liveImage = $stsJson.spec.template.spec.containers[0].image
    $liveReplicas = $stsJson.spec.replicas
    $readyReplicas = $stsJson.status.readyReplicas
    Write-Host "  Image:    $liveImage" -ForegroundColor Gray
    Write-Host "  Replicas: $readyReplicas/$liveReplicas ready" -ForegroundColor Gray

    $container = $stsJson.spec.template.spec.containers[0]
    $liveStartup = if ($container.startupProbe) { "timeout=$($container.startupProbe.timeoutSeconds)s, failures=$($container.startupProbe.failureThreshold)" } else { "disabled" }
    $liveReadiness = if ($container.readinessProbe) { "timeout=$($container.readinessProbe.timeoutSeconds)s, failures=$($container.readinessProbe.failureThreshold)" } else { "disabled" }
    $liveLiveness = if ($container.livenessProbe) { "timeout=$($container.livenessProbe.timeoutSeconds)s, failures=$($container.livenessProbe.failureThreshold)" } else { "disabled" }
    Write-Host "  Probes:   startup=[$liveStartup]  readiness=[$liveReadiness]  liveness=[$liveLiveness]" -ForegroundColor Gray
}

# =============================================================================
# MODE: ProbeOnly -- patch probe timeouts directly on StatefulSet
# =============================================================================
if ($Mode -eq "ProbeOnly") {
    Write-Host ""
    Write-Host "[INFO] ProbeOnly mode: patching probe timeouts on StatefulSet..." -ForegroundColor Cyan

    if ($SkipProbes) {
        Write-Host "[SKIP] -SkipProbes specified, nothing to do in ProbeOnly mode." -ForegroundColor Yellow
        exit 0
    }

    # Parse probe --set flags from the .sh and extract the numeric values
    $rawSets = Parse-HelmSets -ScriptPath $deployScript -BlockType "install"
    $probePatches = @()

    # Map Helm value keys → JSON patch paths
    $probeMap = @{
        "startupProbe.timeoutSeconds"      = "/spec/template/spec/containers/0/startupProbe/timeoutSeconds"
        "startupProbe.periodSeconds"       = "/spec/template/spec/containers/0/startupProbe/periodSeconds"
        "startupProbe.failureThreshold"    = "/spec/template/spec/containers/0/startupProbe/failureThreshold"
        "startupProbe.initialDelaySeconds" = "/spec/template/spec/containers/0/startupProbe/initialDelaySeconds"
        "readinessProbe.timeoutSeconds"    = "/spec/template/spec/containers/0/readinessProbe/timeoutSeconds"
        "readinessProbe.periodSeconds"     = "/spec/template/spec/containers/0/readinessProbe/periodSeconds"
        "livenessProbe.timeoutSeconds"     = "/spec/template/spec/containers/0/livenessProbe/timeoutSeconds"
        "livenessProbe.periodSeconds"      = "/spec/template/spec/containers/0/livenessProbe/periodSeconds"
        "livenessProbe.failureThreshold"   = "/spec/template/spec/containers/0/livenessProbe/failureThreshold"
        "livenessProbe.initialDelaySeconds"= "/spec/template/spec/containers/0/livenessProbe/initialDelaySeconds"
    }

    foreach ($entry in $probeMap.GetEnumerator()) {
        if ($rawSets.Contains($entry.Key)) {
            $probePatches += @{
                op    = "replace"
                path  = $entry.Value
                value = [int](Resolve-BashVar -Expr $rawSets[$entry.Key] -Env $envVars)
            }
        }
    }

    $patchJson = $probePatches | ConvertTo-Json -Depth 5 -Compress
    Write-Host "  Patch: $($probePatches.Count) probe fields (from deploy-mariadb-galera.sh)" -ForegroundColor Gray

    if ($DryRun) {
        Write-Host ""
        Write-Host "  [DRY-RUN] Would apply:" -ForegroundColor Yellow
        $probePatches | ConvertTo-Json -Depth 5 | Write-Host
        exit 0
    }

    $result = oc patch statefulset $ReleaseName -n $Namespace --type=json -p $patchJson 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Patch failed: $result" -ForegroundColor Red
        exit 1
    }
    Write-Host "[OK] Probe timeouts patched" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Note: Existing pods keep old probe settings until restarted." -ForegroundColor Gray
    Write-Host "  To rolling-restart: oc rollout restart statefulset/$ReleaseName -n $Namespace" -ForegroundColor Gray
    exit 0
}

# =============================================================================
# PARSE --set FLAGS FROM DEPLOY SCRIPT
# =============================================================================
Write-Host ""
Write-Host "[INFO] Parsing Helm flags from deploy-mariadb-galera.sh..." -ForegroundColor Cyan

$blockType = if ($Mode -eq "Install") { "install" } else { "install" }
# Note: We always parse the "install" block because it's the most complete.
# For upgrades, we'll add --reuse-values and flip bootstrap flags.

$rawSets = Parse-HelmSets -ScriptPath $deployScript -BlockType $blockType

if ($rawSets.Count -eq 0) {
    Write-Host "[ERROR] No --set flags found in deploy script. Has the format changed?" -ForegroundColor Red
    Write-Host "  Expected: 'helm install `$DB_DEPLOYMENT_NAME' block with --set flags" -ForegroundColor Gray
    exit 1
}

Write-Host "  Parsed $($rawSets.Count) --set flags from 'helm $blockType' block" -ForegroundColor DarkGray

# =============================================================================
# RESOLVE VARIABLES AND BUILD FINAL SET LIST
# =============================================================================

# Validate mode vs release state
if ($Mode -eq "Install" -and $releaseExists) {
    Write-Host "[ERROR] Helm release already exists. Use -Mode Upgrade instead." -ForegroundColor Red
    Write-Host "  To force reinstall: helm uninstall $ReleaseName -n $Namespace (DESTROYS DATA)" -ForegroundColor Yellow
    exit 1
}
if ($Mode -eq "Upgrade" -and -not $releaseExists) {
    Write-Host "[ERROR] No Helm release found. Use -Mode Install for first deployment." -ForegroundColor Red
    exit 1
}

$helmSets = [ordered]@{}
$unresolvedVars = @()

foreach ($entry in $rawSets.GetEnumerator()) {
    $key = $entry.Key
    $rawValue = $entry.Value
    $resolved = Resolve-BashVar -Expr $rawValue -Env $envVars

    # Track unresolved variables (still contain $)
    if ($resolved -match '\$') {
        $unresolvedVars += "$key = $rawValue (unresolved)"
    }

    $helmSets[$key] = $resolved
}

# For Upgrade mode: override bootstrap flags (must be false for running cluster)
if ($Mode -eq "Upgrade") {
    $helmSets["galera.bootstrap.forceBootstrap"] = "false"
    $helmSets["galera.bootstrap.forceSafeToBootstrap"] = "false"
    $helmSets["replicaCount"] = "$Replicas"
}

# For Install mode: force replicaCount=1 (bootstrap first, scale later)
if ($Mode -eq "Install") {
    $helmSets["replicaCount"] = "1"
}

# Warn about unresolved variables
if ($unresolvedVars.Count -gt 0) {
    Write-Host ""
    Write-Host "[WARN] $($unresolvedVars.Count) variable(s) could not be resolved:" -ForegroundColor Yellow
    foreach ($uv in $unresolvedVars) {
        Write-Host "    $uv" -ForegroundColor Yellow
    }
    Write-Host "  Check .env files or pass values via environment variables." -ForegroundColor Yellow
}

# Skip probe flags if requested
if ($SkipProbes) {
    $probeKeys = @($helmSets.Keys | Where-Object { $_ -match 'Probe\.' })
    foreach ($pk in $probeKeys) {
        $helmSets.Remove($pk)
    }
    Write-Host "  Skipped $($probeKeys.Count) probe flags (-SkipProbes)" -ForegroundColor DarkGray
}

# =============================================================================
# BUILD HELM COMMAND
# =============================================================================

$helmAction = if ($Mode -eq "Install") { "install" } else { "upgrade" }
$helmArgs = @($helmAction, $ReleaseName, $ChartRef)

foreach ($entry in $helmSets.GetEnumerator()) {
    $helmArgs += "--set"
    $helmArgs += "$($entry.Key)=$($entry.Value)"
}

if ($Mode -eq "Upgrade") {
    $helmArgs += "--reuse-values"
}

if ($DryRun) {
    $helmArgs += "--dry-run"
    $helmArgs += "--debug"
}

# =============================================================================
# PREVIEW
# =============================================================================
Write-Host ""
Write-Host "  Helm $helmAction $ReleaseName" -ForegroundColor White
Write-Host "  Chart: $ChartRef" -ForegroundColor Gray
Write-Host "  Flags: $($helmSets.Count) --set values (parsed from .sh)" -ForegroundColor Gray

# Show all values (passwords are no longer in --set flags -- they're in existingSecret)
Write-Host ""
foreach ($entry in $helmSets.GetEnumerator()) {
    Write-Host "    --set $($entry.Key)=$($entry.Value)" -ForegroundColor Gray
}

if ($Mode -eq "Upgrade") {
    Write-Host "    --reuse-values" -ForegroundColor Gray
}
if ($DryRun) {
    Write-Host "    --dry-run --debug" -ForegroundColor Yellow
}

# =============================================================================
# CONFIRMATION
# =============================================================================
if (-not $DryRun) {
    Write-Host ""
    Write-Host "  Target: $ReleaseName in $Namespace ($helmAction)" -ForegroundColor White

    $confirm = Read-Host "  Proceed? [y/N]"
    if ($confirm -notin @("y", "Y", "yes")) {
        Write-Host "[ABORT] Cancelled by user" -ForegroundColor Yellow
        exit 0
    }
}

# =============================================================================
# ENSURE CREDENTIALS SECRET
# Mirrors: deploy-mariadb-galera.sh Tier 1.5
# Passwords are stored in a K8s Secret, not in Helm values.
# =============================================================================
Write-Host ""
Write-Host "[INFO] Ensuring credentials secret..." -ForegroundColor Cyan

$dbPassword = $envVars["DB_PASSWORD"]
if (-not $dbPassword) {
    Write-Host "[ERROR] DB_PASSWORD not available. Cannot ensure credentials secret." -ForegroundColor Red
    exit 1
}

# Create/update the secret idempotently (same as .sh: --dry-run=client | apply)
$secretYaml = oc create secret generic $ReleaseName `
    --from-literal=mariadb-root-password="$dbPassword" `
    --from-literal=mariadb-password="$dbPassword" `
    --from-literal=mariadb-galera-mariabackup-password="$dbPassword" `
    --dry-run=client --save-config -o yaml 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to generate secret YAML: $secretYaml" -ForegroundColor Red
    exit 1
}

# Apply may warn about missing annotation on first run (Helm-created secret) -- safe to ignore
$applyOutput = ($secretYaml | oc apply -f -) 2>&1
$applyExitCode = $LASTEXITCODE
if ($applyExitCode -ne 0) {
    Write-Host "[ERROR] Failed to apply credentials secret" -ForegroundColor Red
    exit 1
}

# Prevent Helm from deleting this secret
oc annotate secret $ReleaseName helm.sh/resource-policy=keep --overwrite 2>$null | Out-Null
oc label secret $ReleaseName app.kubernetes.io/name=$ReleaseName --overwrite 2>$null | Out-Null

Write-Host "[OK] Credentials secret verified (passwords in K8s Secret, not Helm values)" -ForegroundColor Green

# =============================================================================
# EXECUTE
# =============================================================================
Write-Host ""
Write-Host "[INFO] Running: helm $helmAction ..." -ForegroundColor Cyan

$output = & helm @helmArgs 2>&1 | Out-String
$helmExitCode = $LASTEXITCODE

Write-Host $output

if ($helmExitCode -ne 0) {
    Write-Host "[ERROR] Helm $helmAction failed (exit code: $helmExitCode)" -ForegroundColor Red
    exit 1
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY-RUN] No changes applied." -ForegroundColor Yellow
    exit 0
}

Write-Host "[OK] Helm $helmAction completed" -ForegroundColor Green

# =============================================================================
# POST-DEPLOY: Wait for bootstrap (Install mode) and scale-out
# =============================================================================
if ($Mode -eq "Install") {
    Write-Host ""
    Write-Host "[INFO] Waiting for ${ReleaseName}-0 to bootstrap..." -ForegroundColor Cyan

    $maxAttempts = 60
    for ($i = 0; $i -lt $maxAttempts; $i++) {
        $podJson = oc get pod "${ReleaseName}-0" -n $Namespace -o json 2>&1 | ConvertFrom-Json
        $readyCondition = $podJson.status.conditions | Where-Object { $_.type -eq "Ready" }
        if ($readyCondition -and $readyCondition.status -eq "True") {
            Write-Host "[OK] ${ReleaseName}-0 is Ready (bootstrapped)" -ForegroundColor Green
            break
        }
        if ($i % 6 -eq 0 -and $i -gt 0) {
            Write-Host "  Still waiting... $($i * 10)s elapsed" -ForegroundColor Gray
        }
        Start-Sleep -Seconds 10
    }

    if ($i -ge $maxAttempts) {
        Write-Host "[ERROR] ${ReleaseName}-0 failed to bootstrap within 600s" -ForegroundColor Red
        exit 1
    }

    # Scale to target replicas (mirrors .sh Step 6)
    if ($Replicas -gt 1) {
        Write-Host ""
        Write-Host "[INFO] Scaling to $Replicas replicas (disabling bootstrap)..." -ForegroundColor Cyan

        $scaleArgs = @(
            "upgrade", $ReleaseName, $ChartRef,
            "--set", "galera.bootstrap.forceBootstrap=false",
            "--set", "galera.bootstrap.forceSafeToBootstrap=false",
            "--set", "replicaCount=$Replicas",
            "--set", "extraFlags=",
            "--set", "mariadbd.extraFlags=",
            "--reuse-values"
        )

        $scaleOutput = & helm @scaleArgs 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] Scale-out failed" -ForegroundColor Red
            Write-Host $scaleOutput
            exit 1
        }
        Write-Host "[OK] Scale-out to $Replicas replicas submitted" -ForegroundColor Green
    }
}

# =============================================================================
# POST-DEPLOY: Verify rollout
# =============================================================================
Write-Host ""
Write-Host "[INFO] Waiting for StatefulSet rollout..." -ForegroundColor Cyan

$rollout = oc rollout status statefulset/$ReleaseName -n $Namespace --timeout=600s 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "[OK] Rollout complete" -ForegroundColor Green
} else {
    Write-Host "[WARN] Rollout timeout or error:" -ForegroundColor Yellow
    Write-Host $rollout -ForegroundColor Yellow
}

# Show final state
Write-Host ""
Write-Host "[INFO] Final state:" -ForegroundColor Cyan
try {
    $finalSts = oc get statefulset $ReleaseName -n $Namespace -o json 2>&1 | ConvertFrom-Json
    $finalContainer = $finalSts.spec.template.spec.containers[0]
    Write-Host "  Image:     $($finalContainer.image)" -ForegroundColor Gray
    Write-Host "  Replicas:  $($finalSts.status.readyReplicas)/$($finalSts.spec.replicas)" -ForegroundColor Gray
    $sTimeout = if ($finalContainer.startupProbe) { "$($finalContainer.startupProbe.timeoutSeconds)s" } else { "disabled" }
    $rTimeout = if ($finalContainer.readinessProbe) { "$($finalContainer.readinessProbe.timeoutSeconds)s" } else { "disabled" }
    $lTimeout = if ($finalContainer.livenessProbe) { "$($finalContainer.livenessProbe.timeoutSeconds)s" } else { "disabled" }
    Write-Host "  Probes:    startup=${sTimeout}  readiness=${rTimeout}  liveness=${lTimeout}" -ForegroundColor Gray
} catch {
    Write-Host "  Could not read final state" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  [SUCCESS] DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
