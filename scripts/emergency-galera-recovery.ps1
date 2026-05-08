# =============================================================================
# EMERGENCY GALERA CLUSTER RECOVERY
# =============================================================================
# Purpose: Execute galera_safe_upgrade() via pod-health-monitor
# Use when: All Galera pods stuck in CrashLoopBackOff with "safe_to_bootstrap: 0"
#
# Prerequisites:
#   - pod-health-monitor deployment must be available (even in MANUAL_MODE)
#   - If monitor is down, this script will provide recovery instructions
#
# Executes: galera_safe_upgrade() from database.sh utility library
#   - Single source of truth for recovery procedure
#   - Includes all defensive steps (grastate.dat fix, env vars, etc.)
#   - Automatic health verification after recovery
#
# WARNING: This will temporarily take the database offline (2-5 minutes)
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('950003-dev', '950003-test', '950003-prod')]
    [string]$Namespace = '950003-prod',

    [Parameter(Mandatory=$false)]
    [int]$TargetReplicas = 0,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "EMERGENCY GALERA RECOVERY" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan
Write-Host "Mode: $(if ($DryRun) { 'DRY RUN' } else { 'EXECUTE' })" -ForegroundColor $(if ($DryRun) { 'Green' } else { 'Red' })
Write-Host ""

# Get current cluster state
Write-Host "[INFO] Current Galera Cluster State:" -ForegroundColor Cyan
oc get statefulset mariadb-galera -n $Namespace -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas
oc get pods -l app.kubernetes.io/name=mariadb-galera -n $Namespace

Write-Host ""
Write-Host "[CHECK] Checking for CrashLoopBackOff..." -ForegroundColor Cyan
$crashingPods = oc get pods -l app.kubernetes.io/name=mariadb-galera -n $Namespace -o json | ConvertFrom-Json
$hasCrashes = $false
foreach ($pod in $crashingPods.items) {
    $state = $pod.status.containerStatuses[0].state
    if ($state.waiting -and $state.waiting.reason -eq 'CrashLoopBackOff') {
        Write-Host "  [ERROR] $($pod.metadata.name): CrashLoopBackOff" -ForegroundColor Red
        $hasCrashes = $true
    }
}

if (-not $hasCrashes) {
    Write-Host "  [INFO] No CrashLoopBackOff detected - cluster may be recovering" -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-Host "Continue with recovery anyway? (yes/no)"
    if ($continue -ne 'yes') {
        Write-Host "[ABORT] Aborted by user" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "[DIAGNOSTIC] This will execute the galera_safe_upgrade procedure:" -ForegroundColor Yellow
Write-Host "  Via: pod-health-monitor > galera_safe_upgrade($targetReplicas)" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Pre-flight verification (skip if all pods crashing)" -ForegroundColor Gray
Write-Host "  2. Save replica count annotation" -ForegroundColor Gray
Write-Host "  3. Scale StatefulSet to 0 (all pods deleted)" -ForegroundColor Gray
Write-Host "  4. Delete secondary PVCs (galera-1, galera-2, etc.)" -ForegroundColor Gray
Write-Host "  5. Fix grastate.dat on galera-0 PVC (safe_to_bootstrap=1)" -ForegroundColor Gray
Write-Host "  6. Set bootstrap environment variables" -ForegroundColor Gray
Write-Host "  7. Scale to 1 (galera-0 bootstraps)" -ForegroundColor Gray
Write-Host "  8. Wait for galera-0 Ready" -ForegroundColor Gray
Write-Host "  9. Clear bootstrap env vars" -ForegroundColor Gray
Write-Host " 10. Scale to $targetReplicas replicas (final state)" -ForegroundColor Cyan
Write-Host " 11. Wait for cluster synchronization + health check" -ForegroundColor Gray
Write-Host ""
Write-Host "[WARNING] Database will be offline during recovery (2-5 minutes)" -ForegroundColor Red
Write-Host ""

if (-not $DryRun) {
    $confirm = Read-Host "Type 'RECOVER' to proceed with emergency recovery"
    if ($confirm -ne 'RECOVER') {
        Write-Host "[ABORT] Recovery cancelled" -ForegroundColor Yellow
        exit 0
    }
}

Write-Host ""
Write-Host "[START] Starting emergency recovery..." -ForegroundColor Green
Write-Host ""

# Get current replica count
$currentReplicas = (oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.spec.replicas}')
Write-Host "Current replica count: $currentReplicas" -ForegroundColor Cyan

# Determine target replica count
$targetReplicas = $TargetReplicas

if ($targetReplicas -eq 0 -and $currentReplicas -gt 0) {
    # Use current replica count
    $targetReplicas = $currentReplicas
    Write-Host "Target replica count: $targetReplicas (current)" -ForegroundColor Cyan
} elseif ($targetReplicas -gt 0) {
    # Use parameter value
    Write-Host "Target replica count: $targetReplicas (specified via parameter)" -ForegroundColor Cyan
} else {
    # Both are 0 - read from CSV or use defaults
    Write-Host "Detecting target replica count from right-sizing CSV..." -ForegroundColor Cyan

    $sizingCsv = ".\openshift\$Namespace-sizing.csv"
    if (Test-Path $sizingCsv) {
        try {
            $csv = Import-Csv $sizingCsv
            $galeraRow = $csv | Where-Object { $_.Deployment -eq "mariadb-galera" }
            if ($galeraRow) {
                $targetReplicas = [int]$galeraRow.'Pod Count'
                Write-Host "  Right-sizing CSV: $targetReplicas replicas" -ForegroundColor Green
                Write-Host "  Source: $sizingCsv" -ForegroundColor Gray
            }
        } catch {
            Write-Host "  [WARNING] Could not read CSV: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Fallback to annotation if CSV failed
    if ($targetReplicas -eq 0) {
        $annotation = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.metadata.annotations.last-known-replicas}' 2>$null
        if (-not [string]::IsNullOrWhiteSpace($annotation) -and $annotation -match '^\d+$' -and [int]$annotation -gt 0) {
            $targetReplicas = [int]$annotation
            Write-Host "  Annotation: $targetReplicas replicas" -ForegroundColor Gray
        }
    }

    # Final fallback to environment defaults
    if ($targetReplicas -eq 0) {
        $targetReplicas = switch ($Namespace) {
            "950003-prod" { 5 }
            "950003-test" { 2 }
            "950003-dev"  { 2 }
            default       { 2 }
        }
        Write-Host "  Environment default: $targetReplicas replicas" -ForegroundColor Gray
    }
}

# Validate final replica count
if ($targetReplicas -lt 1 -or $targetReplicas -gt 10) {
    Write-Host ""
    Write-Host "[ERROR] Invalid target replica count: $targetReplicas (must be 1-10)" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Check if pod-health-monitor is available
Write-Host "[CHECK] Checking pod-health-monitor availability..." -ForegroundColor Cyan
$monitorAvailable = $false
$monitorPod = oc get pods -l app=pod-health-monitor -n $Namespace -o jsonpath='{.items[0].metadata.name}' 2>$null

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($monitorPod)) {
    # Check if pod is Ready - use simpler approach
    $podJson = oc get pod $monitorPod -n $Namespace -o json 2>$null | ConvertFrom-Json
    $readyCondition = $podJson.status.conditions | Where-Object { $_.type -eq "Ready" }
    $monitorReady = $readyCondition.status

    if ($monitorReady -eq "True") {
        Write-Host "  [OK] pod-health-monitor is available ($monitorPod)" -ForegroundColor Green
        $monitorAvailable = $true
    } else {
        Write-Host "  [WARNING] pod-health-monitor pod exists but not Ready" -ForegroundColor Yellow
        Write-Host "     Pod: $monitorPod" -ForegroundColor Gray
        Write-Host "     Status: $monitorReady" -ForegroundColor Gray
    }
} else {
    Write-Host "  [ERROR] pod-health-monitor deployment not found" -ForegroundColor Red
}

if (-not $monitorAvailable) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  CANNOT PROCEED: pod-health-monitor is not available" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    Write-Host "The recovery procedure requires pod-health-monitor to execute" -ForegroundColor Yellow
    Write-Host "galera_safe_upgrade() from the utility library." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "📋 Recovery Options:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Option 1: Deploy/Fix pod-health-monitor (RECOMMENDED)" -ForegroundColor White
    Write-Host "  # Upload scripts" -ForegroundColor Gray
    Write-Host "  .\scripts\update-pod-health-scripts.ps1 -Namespace $Namespace" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  # Check if deployment exists" -ForegroundColor Gray
    Write-Host "  oc get deployment pod-health-monitor -n $Namespace" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  # If deployment missing, create it:" -ForegroundColor Gray
    Write-Host "  oc apply -f .\openshift\pod-health-monitor.yml" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  # If deployment exists but broken, restart it:" -ForegroundColor Gray
    Write-Host "  oc rollout restart deployment/pod-health-monitor -n $Namespace" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  # Wait for it to be ready, then re-run this script" -ForegroundColor Gray
    Write-Host "  oc get pods -l app=pod-health-monitor -n $Namespace -w" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Option 2: Manual Recovery (EMERGENCY ONLY)" -ForegroundColor White
    Write-Host "  Use the manual steps in:" -ForegroundColor Gray
    Write-Host "  .\scripts\EMERGENCY-GALERA-RECOVERY.sh" -ForegroundColor Gray
    Write-Host ""
    exit 1
}

if ($DryRun) {
    Write-Host ""
    Write-Host "[DRY RUN] Would execute:" -ForegroundColor Yellow
    Write-Host "  oc exec $monitorPod -n $Namespace -- bash -c 'source /scripts/_utils.sh `&`& galera_emergency_recovery mariadb-galera $targetReplicas $Namespace'" -ForegroundColor Gray
    Write-Host ""
    Write-Host "This will execute the complete galera_safe_upgrade procedure:" -ForegroundColor Gray
    Write-Host "  1. Pre-flight verification (or skip if all pods crashing)" -ForegroundColor Gray
    Write-Host "  2. Scale StatefulSet to 0" -ForegroundColor Gray
    Write-Host "  3. Delete secondary PVCs" -ForegroundColor Gray
    Write-Host "  4. Fix grastate.dat (safe_to_bootstrap=1)" -ForegroundColor Gray
    Write-Host "  5. Enable bootstrap env vars" -ForegroundColor Gray
    Write-Host "  6. Scale to 1 (galera-0 bootstraps)" -ForegroundColor Gray
    Write-Host "  7. Wait for galera-0 Ready" -ForegroundColor Gray
    Write-Host "  8. Disable bootstrap env vars" -ForegroundColor Gray
    Write-Host "  9. Scale to $targetReplicas replicas" -ForegroundColor Gray
    Write-Host " 10. Wait for cluster sync & health check" -ForegroundColor Gray
    Write-Host ""
    Write-Host "[OK] Dry run complete - no changes made" -ForegroundColor Green
    exit 0
}

# Execute galera_emergency_recovery via pod-health-monitor
Write-Host ""
Write-Host "[EXEC] Executing galera_emergency_recovery via pod-health-monitor..." -ForegroundColor Cyan
Write-Host "   This may take 2-5 minutes..." -ForegroundColor Gray
Write-Host ""

$command = "source /scripts/_utils.sh && galera_emergency_recovery mariadb-galera $targetReplicas $Namespace"
oc exec $monitorPod -n $Namespace -- bash -c $command

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "[SUCCESS] Emergency recovery completed successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "[INFO] Final cluster state:" -ForegroundColor Cyan
    oc get statefulset mariadb-galera -n $Namespace -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas
    oc get pods -l app.kubernetes.io/name=mariadb-galera -n $Namespace
    Write-Host ""
    Write-Host "[CHECK] Verify cluster health:" -ForegroundColor Cyan
    Write-Host "  oc exec mariadb-galera-0 -n $Namespace -c mariadb-galera -- bash -c 'mysql -u root -p`"`$(cat /opt/bitnami/mariadb/secrets/mariadb-root-password)`" -e `"SHOW STATUS LIKE '\''wsrep_cluster%'\''`"`''" -ForegroundColor Gray
} else {
    Write-Host ""
    Write-Host "[FAIL] Recovery failed - see output above for details" -ForegroundColor Red
    Write-Host ""
    Write-Host "[TROUBLESHOOTING]" -ForegroundColor Yellow
    Write-Host "  1. Check pod-health-monitor logs:" -ForegroundColor Gray
    Write-Host "     oc logs $monitorPod -n $Namespace --tail=100" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  2. Check galera pod logs:" -ForegroundColor Gray
    Write-Host "     oc logs mariadb-galera-0 -n $Namespace -c mariadb-galera --tail=100" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  3. Check galera pod status:" -ForegroundColor Gray
    Write-Host "     oc describe pod mariadb-galera-0 -n $Namespace" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  4. If all else fails, use manual recovery:" -ForegroundColor Gray
    Write-Host "     See: scripts\EMERGENCY-GALERA-RECOVERY.sh" -ForegroundColor Gray
    Write-Host ""
    exit 1
}
