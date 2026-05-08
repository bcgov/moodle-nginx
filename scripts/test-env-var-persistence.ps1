<#
.SYNOPSIS
    Test whether direct environment variable updates persist through Helm operations.

.DESCRIPTION
    This script helps determine if MARIADB_EXTRA_FLAGS set via 'oc set env' will
    be preserved or overridden during Helm upgrade operations.

.PARAMETER Namespace
    OpenShift namespace to test in (recommend 950003-dev)

.EXAMPLE
    .\test-env-var-persistence.ps1 -Namespace 950003-dev
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Namespace
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Environment Variable Persistence Test" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Step 1: Capture current state
Write-Host "[Step 1] Checking current configuration..." -ForegroundColor Yellow
Write-Host ""

# Check if Helm-managed
$helmRelease = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>$null
if ($LASTEXITCODE -eq 0 -and $helmRelease) {
    Write-Host "  Helm Release: $helmRelease" -ForegroundColor Green
    $isHelmManaged = $true
} else {
    Write-Host "  [WARNING] Not Helm-managed - test may not be relevant" -ForegroundColor Yellow
    $isHelmManaged = $false
}

# Get current MARIADB_EXTRA_FLAGS from StatefulSet spec
$currentEnvFlags = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MARIADB_EXTRA_FLAGS")].value}' 2>$null
if ($currentEnvFlags) {
    Write-Host "  Current MARIADB_EXTRA_FLAGS:" -ForegroundColor Cyan
    Write-Host "    $currentEnvFlags" -ForegroundColor White
} else {
    Write-Host "  MARIADB_EXTRA_FLAGS: (not set)" -ForegroundColor Gray
}

# Get current Helm values (if Helm-managed)
if ($isHelmManaged) {
    Write-Host ""
    Write-Host "  Checking Helm values..." -ForegroundColor Cyan
    $helmValues = helm get values $helmRelease -n $Namespace 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Current Helm values:" -ForegroundColor Cyan
        Write-Host $helmValues -ForegroundColor Gray
    }
}

# Step 2: Propose test
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Test Proposal" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "We will:" -ForegroundColor Yellow
Write-Host "  1. Set MARIADB_EXTRA_FLAGS via 'oc set env' (direct update)" -ForegroundColor White
Write-Host "  2. Verify pods restart and pick up the change" -ForegroundColor White
Write-Host "  3. Run 'helm upgrade --reuse-values' with NO changes" -ForegroundColor White
Write-Host "  4. Check if environment variable persists or gets removed" -ForegroundColor White
Write-Host ""
Write-Host "This tells us: Can we use direct env updates, or MUST we use Helm?" -ForegroundColor Cyan
Write-Host ""

# Safety check
$confirm = Read-Host "Run this test in namespace $Namespace? (yes/no)"
if ($confirm -ne "yes") {
    Write-Host "Test cancelled." -ForegroundColor Yellow
    exit 0
}

# Step 3: Set environment variable directly
Write-Host ""
Write-Host "[Step 2] Setting MARIADB_EXTRA_FLAGS via oc set env..." -ForegroundColor Yellow
$testValue = '--wsrep-provider-options="evs.inactive_timeout=PT25S;evs.suspect_timeout=PT10S"'
Write-Host "  Value: $testValue" -ForegroundColor Cyan

oc set env statefulset/mariadb-galera MARIADB_EXTRA_FLAGS="$testValue" -n $Namespace
if ($LASTEXITCODE -ne 0) {
    Write-Host "  [ERROR] Failed to set environment variable" -ForegroundColor Red
    exit 1
}

Write-Host "  [OK] Environment variable set" -ForegroundColor Green

# Wait for rollout
Write-Host ""
Write-Host "[Step 3] Waiting for StatefulSet rollout..." -ForegroundColor Yellow
Write-Host "  (This may take 2-5 minutes)" -ForegroundColor Gray

$timeout = 300
oc rollout status statefulset/mariadb-galera -n $Namespace --timeout="${timeout}s" 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "  [OK] Rollout complete" -ForegroundColor Green
} else {
    Write-Host "  [WARNING] Rollout may be slow, checking pods..." -ForegroundColor Yellow
    oc get pods -n $Namespace -l app.kubernetes.io/name=mariadb-galera
}

# Verify env var in pod
Write-Host ""
Write-Host "[Step 4] Verifying environment variable in pod..." -ForegroundColor Yellow
$pod = oc get pods -n $Namespace -l app.kubernetes.io/name=mariadb-galera -o jsonpath='{.items[0].metadata.name}' 2>$null
if ($pod) {
    $podEnvValue = oc exec $pod -n $Namespace -- env | Select-String "MARIADB_EXTRA_FLAGS"
    Write-Host "  Pod: $pod" -ForegroundColor Cyan
    Write-Host "  $podEnvValue" -ForegroundColor White
} else {
    Write-Host "  [WARNING] No pods found" -ForegroundColor Yellow
}

# Step 4: Helm upgrade (no changes)
if ($isHelmManaged) {
    Write-Host ""
    Write-Host "[Step 5] Running Helm upgrade with --reuse-values..." -ForegroundColor Yellow
    Write-Host "  (This simulates routine Helm operations)" -ForegroundColor Gray
    
    helm upgrade $helmRelease bitnami/mariadb-galera -n $Namespace --reuse-values 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  [OK] Helm upgrade complete" -ForegroundColor Green
    } else {
        Write-Host "  [ERROR] Helm upgrade failed" -ForegroundColor Red
        exit 1
    }

    # Wait for any potential rollout
    Write-Host ""
    Write-Host "[Step 6] Checking if Helm triggered rollout..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10

    # Check env var again
    Write-Host ""
    Write-Host "[Step 7] Checking environment variable after Helm upgrade..." -ForegroundColor Yellow
    $newEnvFlags = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MARIADB_EXTRA_FLAGS")].value}' 2>$null
    
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host " TEST RESULTS" -ForegroundColor Cyan
    Write-Host "============================================" -ForegroundColor Cyan
    Write-Host ""
    
    Write-Host "Before Helm upgrade:" -ForegroundColor Cyan
    Write-Host "  $testValue" -ForegroundColor White
    Write-Host ""
    Write-Host "After Helm upgrade:" -ForegroundColor Cyan
    if ($newEnvFlags) {
        Write-Host "  $newEnvFlags" -ForegroundColor White
        
        if ($newEnvFlags -eq $testValue) {
            Write-Host ""
            Write-Host "  [SUCCESS] Environment variable PERSISTED!" -ForegroundColor Green
            Write-Host "  Direct env updates are SAFE with this Helm chart." -ForegroundColor Green
            Write-Host ""
            Write-Host "  Recommendation: You can use 'oc set env' for immediate changes" -ForegroundColor Yellow
            Write-Host "  without Helm override risk." -ForegroundColor Yellow
        } else {
            Write-Host ""
            Write-Host "  [WARNING] Environment variable CHANGED!" -ForegroundColor Yellow
            Write-Host "  Helm may have modified it." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Recommendation: Use Helm values to ensure persistence." -ForegroundColor Yellow
        }
    } else {
        Write-Host "  (not set)" -ForegroundColor Red
        Write-Host ""
        Write-Host "  [FAILURE] Environment variable REMOVED!" -ForegroundColor Red
        Write-Host "  Helm upgrade cleared the direct env update." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Recommendation: MUST use Helm values for persistent config." -ForegroundColor Yellow
        Write-Host "  Command: helm upgrade $helmRelease bitnami/mariadb-galera -n $Namespace --reuse-values \\" -ForegroundColor Yellow
        Write-Host "           --set extraFlags='$testValue'" -ForegroundColor Yellow
    }
} else {
    Write-Host ""
    Write-Host "[WARNING] Not Helm-managed - cannot test Helm upgrade behavior" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Test complete!" -ForegroundColor Green
Write-Host ""
