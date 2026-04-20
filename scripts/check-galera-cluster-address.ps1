<#
.SYNOPSIS
Detect and fix MARIADB_GALERA_CLUSTER_ADDRESS configuration issues.

.DESCRIPTION
Calls the in-cluster galera-fix-cluster-address.sh script via pod-health-monitor.
This is part of the cloud-native architecture where heavy lifting happens IN the cluster.

This issue causes nodes 1-4 to bootstrap independently instead of joining pod-0.

.PARAMETER Namespace
OpenShift namespace containing the mariadb-galera StatefulSet.

.PARAMETER StatefulSetName
Name of the StatefulSet (default: mariadb-galera).

.PARAMETER Fix
Apply fixes automatically. Without this flag, runs in diagnostic-only mode.

.EXAMPLE
# Diagnostic mode
.\scripts\check-galera-cluster-address.ps1 -Namespace 950003-prod

.EXAMPLE
# Apply fixes
.\scripts\check-galera-cluster-address.ps1 -Namespace 950003-prod -Fix

.NOTES
Architecture: This PowerShell script is a thin wrapper that calls the bash script
running in pod-health-monitor. All logic lives in the cluster for consistency.

Root cause: database.sh Step 7 removed MARIADB_GALERA_CLUSTER_ADDRESS instead
of setting it to the proper discovery address.

.LINK
See: openshift/scripts/utils/galera-fix-cluster-address.sh (in-cluster implementation)
     docs/manual-galera-troubleshooting.md
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Namespace,

    [Parameter(Mandatory=$false)]
    [string]$StatefulSetName = "mariadb-galera",

    [Parameter(Mandatory=$false)]
    [switch]$Fix
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  GALERA CLUSTER ADDRESS DIAGNOSTIC" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""

# Validate OpenShift connection
Write-Host "[INFO] Validating OpenShift connection..." -ForegroundColor Cyan
try {
    $null = oc version --client 2>&1
    if ($LASTEXITCODE -ne 0) { throw "oc CLI not available" }

    $null = oc get namespace $Namespace 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Namespace '$Namespace' not found" }

    Write-Host "  [OK] Connected to namespace: $Namespace" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Find pod-health-monitor pod
Write-Host "[INFO] Finding pod-health-monitor..." -ForegroundColor Cyan
try {
    $podName = oc get pod -l app=pod-health-monitor -n $Namespace -o jsonpath='{.items[0].metadata.name}' 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $podName) {
        throw "pod-health-monitor not found in namespace $Namespace"
    }
    Write-Host "  [OK] Found: $podName" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Build command
$fixFlag = if ($Fix) { " --fix" } else { "" }
$command = "/scripts/utils-galera-fix-cluster-address.sh $Namespace $StatefulSetName$fixFlag"

Write-Host "[INFO] Executing in-cluster diagnostic..." -ForegroundColor Cyan
Write-Host "  Pod: $podName" -ForegroundColor Gray
Write-Host "  Command: $command" -ForegroundColor Gray
Write-Host ""
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""

# Execute the in-cluster script
oc exec $podName -n $Namespace -- bash -c $command

$exitCode = $LASTEXITCODE

Write-Host ""
Write-Host "======================================================================" -ForegroundColor DarkGray

# Interpret exit code
switch ($exitCode) {
    0 {
        Write-Host "[OK] Configuration is correct" -ForegroundColor Green
        exit 0
    }
    1 {
        if ($Fix) {
            Write-Host "[INFO] Issues were detected and fixes were applied" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Next steps:" -ForegroundColor Cyan
            Write-Host "  1. Wait for StatefulSet update to propagate" -ForegroundColor Gray
            Write-Host "  2. If cluster is still unhealthy, run bootstrap recovery:" -ForegroundColor Gray
            Write-Host "     .\scripts\bootstrap-mariadb-galera.ps1 -Namespace $Namespace -Bootstrap" -ForegroundColor White
        } else {
            Write-Host "[INFO] Issues detected (run with -Fix to apply corrections)" -ForegroundColor Yellow
        }
        exit 1
    }
    2 {
        Write-Host "[WARNING] Issues detected in diagnostic mode" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Run with -Fix flag to apply corrections:" -ForegroundColor Cyan
        Write-Host "  .\scripts\check-galera-cluster-address.ps1 -Namespace $Namespace -Fix" -ForegroundColor White
        exit 2
    }
    default {
        Write-Host "[ERROR] Script execution failed (exit code: $exitCode)" -ForegroundColor Red
        exit $exitCode
    }
}
