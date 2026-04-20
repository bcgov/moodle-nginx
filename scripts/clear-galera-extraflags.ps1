<#
.SYNOPSIS
    Clear extraFlags from mariadb-galera Helm release to allow my.cnf to take effect

.DESCRIPTION
    Runs a minimal Helm upgrade that clears MARIADB_EXTRA_FLAGS from the StatefulSet,
    allowing ConfigMap my.cnf settings (PT20S, PT25S, PT30S) to take effect.

    PROBLEM:
      - Previous Helm deployments set extraFlags with PT30S hardcoded
      - This creates MARIADB_EXTRA_FLAGS environment variable
      - Command-line args override my.cnf file settings
      - Our PT20S ConfigMap updates are ignored

    SOLUTION:
      - Helm upgrade with --set extraFlags="" to clear the value
      - Pods restart and pick up my.cnf settings
      - Future Helm deployments preserve the cleared value

.PARAMETER Namespace
    Target OpenShift namespace (e.g., 950003-dev)

.PARAMETER DryRun
    Show what would be done without making changes

.EXAMPLE
    # Clear extraFlags in dev (test first)
    .\scripts\clear-galera-extraflags.ps1 -Namespace 950003-dev

.EXAMPLE
    # Preview changes without applying
    .\scripts\clear-galera-extraflags.ps1 -Namespace 950003-dev -DryRun

.EXAMPLE
    # Clear in production (after testing in dev/test)
    .\scripts\clear-galera-extraflags.ps1 -Namespace 950003-prod

.NOTES
    Run this ONCE to fix existing Helm releases.
    Future deployments via deploy-mariadb-galera.sh will maintain cleared extraFlags.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(Mandatory = $false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

$HelmChart = "mariadb-galera"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  CLEAR MARIADB_EXTRA_FLAGS VIA HELM UPGRADE" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Namespace: $Namespace" -ForegroundColor Gray
Write-Host "  Helm Release: $HelmChart" -ForegroundColor Gray
Write-Host ""

# =============================================================================
# STEP 1: Verify Helm is available
# =============================================================================
Write-Host "[1/5] Checking Helm availability..." -ForegroundColor Cyan
$helmVersion = helm version --short 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Helm not found. Please install Helm:" -ForegroundColor Red
    Write-Host "    https://helm.sh/docs/intro/install/" -ForegroundColor Gray
    exit 1
}
Write-Host "  [OK] $helmVersion" -ForegroundColor Green
Write-Host ""

# =============================================================================
# STEP 2: Check current MARIADB_EXTRA_FLAGS
# =============================================================================
Write-Host "[2/5] Checking current StatefulSet configuration..." -ForegroundColor Cyan

$currentFlags = oc get statefulset/$HelmChart -n $Namespace `
    -o jsonpath="{.spec.template.spec.containers[?(@.name=='mariadb-galera')].env[?(@.name=='MARIADB_EXTRA_FLAGS')].value}" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Could not query StatefulSet: $currentFlags" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($currentFlags)) {
    Write-Host "  [OK] MARIADB_EXTRA_FLAGS not set (already cleared)" -ForegroundColor Green
    Write-Host ""
    Write-Host "No action needed - extraFlags already cleared!" -ForegroundColor Green
    Write-Host ""
    Write-Host "Verification:" -ForegroundColor Gray
    Write-Host "  oc exec mariadb-galera-0 -n $Namespace -c mariadb-galera -- ps aux | Select-String wsrep" -ForegroundColor DarkGray
    exit 0
}

Write-Host "  [FOUND] MARIADB_EXTRA_FLAGS currently set:" -ForegroundColor Yellow
Write-Host "    $currentFlags" -ForegroundColor White
Write-Host ""

# Extract timeout for clarity
if ($currentFlags -match "evs\.inactive_timeout=([^;]+)") {
    Write-Host "  Current timeout: $($matches[1]) (from environment variable)" -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# STEP 3: Check what's in ConfigMap (what SHOULD be active)
# =============================================================================
Write-Host "[3/5] Checking ConfigMap my.cnf settings..." -ForegroundColor Cyan

$configMapContent = oc get configmap mariadb-galera-configuration -n $Namespace `
    -o jsonpath="{.data.my\.cnf}" 2>&1

$configMapTimeout = $null
if ($configMapContent -match 'evs\.inactive_timeout=([^;\"]+)') {
    $configMapTimeout = $matches[1]
}

if ($configMapTimeout) {
    Write-Host "  [OK] ConfigMap timeout: $configMapTimeout" -ForegroundColor Green
    Write-Host "  This SHOULD be active but is overridden by MARIADB_EXTRA_FLAGS" -ForegroundColor Yellow
} else {
    Write-Host "  [WARN] Could not find timeout in ConfigMap" -ForegroundColor Yellow
}
Write-Host ""

# =============================================================================
# STEP 4: Show Helm command
# =============================================================================
Write-Host "[4/5] Helm upgrade command:" -ForegroundColor Cyan
Write-Host ""

$helmCommand = @"
helm upgrade $HelmChart oci://registry-1.docker.io/bitnamicharts/mariadb-galera \
  --namespace $Namespace \
  --reuse-values \
  --set extraFlags="" \
  --set mariadbd.extraFlags=""
"@

if ($DryRun) {
    $helmCommand += " --dry-run"
}

Write-Host $helmCommand -ForegroundColor White
Write-Host ""

# =============================================================================
# STEP 5: Execute or show what would happen
# =============================================================================
if ($DryRun) {
    Write-Host "[5/5] DRY RUN - Showing what would happen..." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "This would:" -ForegroundColor Yellow
    Write-Host "  1. Clear extraFlags in Helm release" -ForegroundColor Gray
    Write-Host "  2. Update StatefulSet spec (remove MARIADB_EXTRA_FLAGS)" -ForegroundColor Gray
    Write-Host "  3. Trigger pod restart (RollingUpdate)" -ForegroundColor Gray
    Write-Host "  4. Pods will pick up ConfigMap my.cnf settings ($configMapTimeout)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Run without -DryRun to apply changes" -ForegroundColor Cyan
} else {
    Write-Host "[5/5] Running Helm upgrade..." -ForegroundColor Cyan
    Write-Host ""

    # Get current revision for comparison
    $helmList = helm list -n $Namespace -o json | ConvertFrom-Json
    $currentRelease = $helmList | Where-Object { $_.name -eq $HelmChart }
    $currentRevision = if ($currentRelease) { $currentRelease.revision } else { "unknown" }

    Write-Host "  Current Helm revision: $currentRevision" -ForegroundColor Gray

    # Run the upgrade
    $upgradeOutput = helm upgrade $HelmChart oci://registry-1.docker.io/bitnamicharts/mariadb-galera `
        --namespace $Namespace `
        --reuse-values `
        --set extraFlags="" `
        --set mariadbd.extraFlags="" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [ERROR] Helm upgrade failed:" -ForegroundColor Red
        Write-Host $upgradeOutput -ForegroundColor Red
        exit 1
    }

    Write-Host "  [OK] Helm upgrade completed" -ForegroundColor Green
    Write-Host ""

    # Get new revision
    $helmList = helm list -n $Namespace -o json | ConvertFrom-Json
    $newRelease = $helmList | Where-Object { $_.name -eq $HelmChart }
    $newRevision = if ($newRelease) { $newRelease.revision } else { "unknown" }

    Write-Host "  New Helm revision: $newRevision" -ForegroundColor Green
    Write-Host ""

    # Verify removal
    Start-Sleep -Seconds 2
    $newFlags = oc get statefulset/$HelmChart -n $Namespace `
        -o jsonpath="{.spec.template.spec.containers[?(@.name=='mariadb-galera')].env[?(@.name=='MARIADB_EXTRA_FLAGS')].value}" 2>&1

    if ([string]::IsNullOrWhiteSpace($newFlags)) {
        Write-Host "  ✅ SUCCESS: MARIADB_EXTRA_FLAGS removed from StatefulSet" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  WARNING: MARIADB_EXTRA_FLAGS still present:" -ForegroundColor Yellow
        Write-Host "    $newFlags" -ForegroundColor White
        Write-Host ""
        Write-Host "  This may indicate the value is in Helm chart defaults." -ForegroundColor Yellow
        Write-Host "  Check with: helm get values $HelmChart -n $Namespace" -ForegroundColor Gray
    }
    Write-Host ""

    # Check if pods are updating
    Write-Host "  Monitoring pod rollout..." -ForegroundColor Cyan
    oc rollout status statefulset/$HelmChart -n $Namespace --timeout=600s

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Pods restarted successfully" -ForegroundColor Green
    } else {
        Write-Host "  [WARN] Rollout timeout or error - check manually" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  NEXT STEPS" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

if (-not $DryRun) {
    Write-Host "Verify running configuration (after pods restart):" -ForegroundColor Gray
    Write-Host "  oc exec mariadb-galera-0 -n $Namespace -c mariadb-galera -- ps aux | Select-String wsrep" -ForegroundColor White
    Write-Host ""
    Write-Host "Expected: Process should show $configMapTimeout (from ConfigMap), not PT30S" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Monitor for split-brain:" -ForegroundColor Gray
    Write-Host "  oc logs -l app.kubernetes.io/name=mariadb-galera -n $Namespace --tail=100 -f | Select-String 'split|inconsistent'" -ForegroundColor White
    Write-Host ""
}

Write-Host "To make this permanent in future deployments:" -ForegroundColor Gray
Write-Host "  The deploy-mariadb-galera.sh script already includes:" -ForegroundColor DarkGray
Write-Host "    --set extraFlags=\"\" \\" -ForegroundColor DarkGray
Write-Host "    --set mariadbd.extraFlags=\"\" \\" -ForegroundColor DarkGray
Write-Host "  Future Helm deployments will maintain cleared extraFlags." -ForegroundColor DarkGray
Write-Host ""
