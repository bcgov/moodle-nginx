#!/usr/bin/env pwsh
#==============================================================================
# update-pod-health-monitor.ps1
#==============================================================================
# PURPOSE:
#   Update the pod-health-monitor deployment with the latest scripts from
#   openshift/scripts/ including the critical utils/database.sh file.
#
# USAGE:
#   .\scripts\update-pod-health-monitor.ps1 -Namespace 950003-prod
#
# WHAT IT DOES:
#   1. Deletes existing openshift-scripts ConfigMap
#   2. Recreates ConfigMap with ALL files from openshift/scripts/ directory
#   3. Restarts pod-health-monitor deployment to load new scripts
#   4. Verifies the critical database.sh file is present
#
# WHY THIS IS NEEDED:
#   The pod-health-monitor runs monitor-pods.sh which sources utils/database.sh
#   for Galera health checks and auto-heal logic. When we update database.sh
#   (e.g., fix split-brain detection), we must recreate the ConfigMap and
#   restart the pod for changes to take effect.
#==============================================================================

param(
    [Parameter(Mandatory=$false)]
    [string]$Namespace = "950003-prod"
)

$ErrorActionPreference = "Stop"

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "Updating pod-health-monitor" -ForegroundColor Cyan
Write-Host "Namespace: $Namespace" -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

# Step 1: Delete existing ConfigMap
Write-Host "`n[1/5] Deleting existing openshift-scripts ConfigMap..." -ForegroundColor Yellow
$deleteResult = oc delete configmap openshift-scripts -n $Namespace 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ✅ ConfigMap deleted" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  ConfigMap not found (may be first-time deployment)" -ForegroundColor Gray
}

# Step 2: Create ConfigMap from openshift/scripts/ directory
Write-Host "`n[2/5] Creating ConfigMap with latest scripts..." -ForegroundColor Yellow
Write-Host "  Including: monitor-pods.sh, check-pod-logs.sh, utils/database.sh, utils/_utils.sh" -ForegroundColor Gray

$createResult = oc create configmap openshift-scripts `
    --from-file=monitor-pods.sh=.\openshift\scripts\monitor-pods.sh `
    --from-file=check-pod-logs.sh=.\openshift\scripts\check-pod-logs.sh `
    --from-file=mariadb-prestop.sh=.\openshift\scripts\mariadb-prestop.sh `
    --from-file=utils/database.sh=.\openshift\scripts\utils\database.sh `
    --from-file=utils/_utils.sh=.\openshift\scripts\utils\_utils.sh `
    --from-file=deploy-mariadb-galera.sh=.\openshift\scripts\deploy-mariadb-galera.sh `
    --from-file=deploy-resource.ps1=.\openshift\scripts\deploy-resource.ps1 `
    --from-file=helm-image-resolver.sh=.\openshift\scripts\helm-image-resolver.sh `
    -n $Namespace 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "  ❌ Failed to create ConfigMap" -ForegroundColor Red
    Write-Host $createResult
    exit 1
}

Write-Host "  ✅ ConfigMap created" -ForegroundColor Green

# Step 3: Label ConfigMap for Helm management
Write-Host "`n[3/5] Labeling ConfigMap..." -ForegroundColor Yellow
oc label configmap openshift-scripts app=pod-health-monitor -n $Namespace --overwrite | Out-Null
Write-Host "  ✅ Labels applied" -ForegroundColor Green

# Step 4: Restart pod-health-monitor deployment
Write-Host "`n[4/5] Restarting pod-health-monitor deployment..." -ForegroundColor Yellow
$rolloutResult = oc rollout restart deployment/pod-health-monitor -n $Namespace 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ❌ Failed to restart deployment" -ForegroundColor Red
    Write-Host $rolloutResult
    exit 1
}

Write-Host "  ⏳ Waiting for new pod to be ready..." -ForegroundColor Gray
Start-Sleep -Seconds 5

$waitResult = oc rollout status deployment/pod-health-monitor -n $Namespace --timeout=120s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "  ❌ Deployment failed tobecome ready" -ForegroundColor Red
    Write-Host $waitResult
    exit 1
}

Write-Host "  ✅ Deployment restarted and ready" -ForegroundColor Green

# Step 5: Verify critical files are present
Write-Host "`n[5/5] Verifying files in container..." -ForegroundColor Yellow

$fileCheck = oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "ls -lh /scripts/utils/database.sh /scripts/utils/_utils.sh /scripts/monitor-pods.sh 2>&1" 2>&1

if ($fileCheck -match "No such file") {
    Write-Host "  ❌ Critical files are missing!" -ForegroundColor Red
    Write-Host $fileCheck
    exit 1
}

Write-Host "  ✅ Critical files verified:" -ForegroundColor Green
$fileCheck | ForEach-Object { Write-Host "    $_" -ForegroundColor Gray }

# Verify database.sh has the updated split-brain logic
Write-Host "`n  Checking for updated split-brain detection logic..." -ForegroundColor Gray
$logicCheck = oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "grep -c 'TRUE SPLIT-BRAIN' /scripts/utils/database.sh" 2>&1

if ($logicCheck -match "^\d+" -and [int]$logicCheck -gt 0) {
    Write-Host "  ✅ Updated split-brain detection logic found" -ForegroundColor Green
} else {
    Write-Host "  ⚠️  Warning: Updated logic not detected - verify database.sh content" -ForegroundColor Yellow
}

Write-Host "`n==================================================" -ForegroundColor Cyan
Write-Host "✅ pod-health-monitor update complete!" -ForegroundColor Green
Write-Host "==================================================" -ForegroundColor Cyan

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Monitor logs: oc logs deployment/pod-health-monitor -n $Namespace -f" -ForegroundColor Cyan
Write-Host "  2. Test monitoring: .\scripts\monitor-galera-splitbrain.ps1 -Namespace $Namespace -Once" -ForegroundColor Cyan
Write-Host "  3. Check cluster: .\scripts\bootstrap-mariadb-galera.ps1 -Namespace $Namespace -Analyze" -ForegroundColor Cyan
Write-Host ""
