<#
.SYNOPSIS
    Upload Galera utility scripts to pod-health-monitor and run diagnostics

.DESCRIPTION
    This script handles ONLY:
    1. Uploading utility scripts to pod-health-monitor ConfigMap
    2. Running diagnostics from your local machine
    3. Viewing logs and configuration status

    All heavy lifting (config updates, pod restarts) happens IN-CLUSTER
    via pod-health-monitor scripts.

.PARAMETER Namespace
    Target OpenShift namespace

.PARAMETER Action
    Action to perform:
    - UploadUtilities: Upload apply-galera-timeouts.sh to pod-health-monitor
    - Diagnose: Run comprehensive diagnostics
    - Verify: Quick verification of current timeout configuration
    - ShowLogs: View pod-health-monitor logs
    - ApplyInCluster: Trigger in-cluster application of timeouts (delegates to pod)

.PARAMETER Profile
    Timeout profile (for ApplyInCluster action): default|minimal|dev|test|production|full

.EXAMPLE
    # Upload latest utility scripts to cluster
    .\manage-galera-utilities.ps1 -Namespace 950003-dev -Action UploadUtilities

.EXAMPLE
    # Run diagnostics from local machine
    .\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Diagnose

.EXAMPLE
    # Trigger in-cluster timeout application (auto-detect profile)
    .\manage-galera-utilities.ps1 -Namespace 950003-prod -Action ApplyInCluster

.EXAMPLE
    # Trigger with specific profile
    .\manage-galera-utilities.ps1 -Namespace 950003-test -Action ApplyInCluster -Profile test

.EXAMPLE
    # Quick verification
    .\manage-galera-utilities.ps1 -Namespace 950003-dev -Action Verify

.NOTES
    PHILOSOPHY: Keep PowerShell simple - diagnostics and file upload only.
    All deployment logic lives in-cluster for cloud-native operations.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(Mandatory=$true)]
    [ValidateSet("UploadUtilities", "Diagnose", "Verify", "ShowLogs", "ApplyInCluster")]
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [ValidateSet("default", "minimal", "dev", "test", "production", "full")]
    [string]$Profile
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  GALERA UTILITIES MANAGEMENT (LOCAL DIAGNOSTICS ONLY)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Namespace: $Namespace" -ForegroundColor Gray
Write-Host "  Action: $Action" -ForegroundColor Gray
Write-Host ""

# Validate OpenShift connection
try {
    $null = oc whoami 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged in to OpenShift"
    }
} catch {
    Write-Host "[ERROR] OpenShift connection failed: $_" -ForegroundColor Red
    exit 1
}

switch ($Action) {
    "UploadUtilities" {
        Write-Host "[INFO] Uploading utility scripts to pod-health-monitor ConfigMap..." -ForegroundColor Cyan
        Write-Host ""

        # Read local utility script
        $utilityScript = "config\pod-health-monitor\utils\apply-galera-timeouts.sh"
        if (-not (Test-Path $utilityScript)) {
            Write-Host "[ERROR] Utility script not found: $utilityScript" -ForegroundColor Red
            exit 1
        }

        $scriptContent = Get-Content $utilityScript -Raw
        Write-Host "  Script: $utilityScript" -ForegroundColor Gray
        Write-Host "  Size: $($scriptContent.Length) bytes" -ForegroundColor Gray
        Write-Host ""

        # Update ConfigMap via script (reuse existing update-pod-health-scripts.ps1)
        if (Test-Path "scripts\update-pod-health-scripts.ps1") {
            Write-Host "[INFO] Using update-pod-health-scripts.ps1..." -ForegroundColor Cyan
            & ".\scripts\update-pod-health-scripts.ps1" -Namespace $Namespace
        } else {
            Write-Host "[WARN] update-pod-health-scripts.ps1 not found, manual upload needed" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "  Manual steps:" -ForegroundColor Gray
            Write-Host "    1. Get ConfigMap: oc get configmap pod-health-monitor-scripts -n $Namespace -o yaml > cm.yaml" -ForegroundColor White
            Write-Host "    2. Edit cm.yaml to add apply-galera-timeouts.sh" -ForegroundColor White
            Write-Host "    3. Apply: oc apply -f cm.yaml" -ForegroundColor White
            Write-Host "    4. Restart: oc rollout restart deployment/pod-health-monitor -n $Namespace" -ForegroundColor White
        }

        Write-Host ""
        Write-Host "[SUCCESS] Utilities uploaded to cluster" -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Verify upload:" -ForegroundColor Gray
        Write-Host "     oc exec deployment/pod-health-monitor -n $Namespace -- ls -lah /scripts/utils/" -ForegroundColor White
        Write-Host ""
        Write-Host "  2. Apply timeouts in-cluster:" -ForegroundColor Gray
        Write-Host "     .\manage-galera-utilities.ps1 -Namespace $Namespace -Action ApplyInCluster" -ForegroundColor White
        Write-Host ""
    }

    "Diagnose" {
        Write-Host "[INFO] Running comprehensive diagnostics..." -ForegroundColor Cyan
        Write-Host ""

        if (Test-Path "scripts\diagnose-galera-config-priority.ps1") {
            & ".\scripts\diagnose-galera-config-priority.ps1" -Namespace $Namespace
        } else {
            Write-Host "[ERROR] Diagnostic script not found" -ForegroundColor Red
            exit 1
        }
    }

    "Verify" {
        Write-Host "[INFO] Quick verification of timeout configuration..." -ForegroundColor Cyan
        Write-Host ""

        # Check ConfigMap
        Write-Host "  [1] ConfigMap Setting:" -ForegroundColor Yellow
        $configMapSettings = oc get configmap mariadb-galera-configuration -n $Namespace -o jsonpath='{.data.my\.cnf}' 2>&1 | Select-String "wsrep_provider_options"
        if ($configMapSettings) {
            Write-Host "      $configMapSettings" -ForegroundColor White
        } else {
            Write-Host "      (not set in ConfigMap)" -ForegroundColor Gray
        }
        Write-Host ""

        # Check runtime (fixed password handling)
        Write-Host "  [2] Runtime Setting:" -ForegroundColor Yellow
        $runtimeCmd = 'mysql -uroot -p$(cat $MARIADB_ROOT_PASSWORD_FILE) -sN -e "SHOW VARIABLES LIKE \"wsrep_provider_options\";"'
        $runtimeResult = oc exec mariadb-galera-0 -n $Namespace -c mariadb-galera -- bash -c $runtimeCmd 2>&1

        if ($LASTEXITCODE -eq 0) {
            # Extract inactive_timeout
            if ($runtimeResult -match "evs\.inactive_timeout\s*=\s*([^;]+)") {
                $timeout = $matches[1].Trim()
                $color = if ($timeout -eq "PT15S") { "Red" } else { "Green" }
                Write-Host "      evs.inactive_timeout = $timeout" -ForegroundColor $color
            } else {
                Write-Host "      (could not parse)" -ForegroundColor Gray
            }
        } else {
            Write-Host "      [ERROR] Could not query MySQL" -ForegroundColor Red
        }
        Write-Host ""

        # In-cluster verification (if utility available)
        Write-Host "  [3] In-Cluster Verification:" -ForegroundColor Yellow
        $inClusterCheck = oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "test -f /scripts/utils/apply-galera-timeouts.sh && echo exists || echo missing" 2>&1

        if ($inClusterCheck -eq "exists") {
            Write-Host "      Utility script: Available" -ForegroundColor Green
            Write-Host ""
            Write-Host "      Run full in-cluster verification:" -ForegroundColor Gray
            Write-Host "      oc exec deployment/pod-health-monitor -n $Namespace -- bash /scripts/utils/apply-galera-timeouts.sh --verify-only" -ForegroundColor White
        } else {
            Write-Host "      Utility script: Not uploaded yet" -ForegroundColor Yellow
            Write-Host "      Run: .\manage-galera-utilities.ps1 -Namespace $Namespace -Action UploadUtilities" -ForegroundColor Gray
        }
        Write-Host ""
    }

    "ShowLogs" {
        Write-Host "[INFO] Fetching pod-health-monitor logs..." -ForegroundColor Cyan
        Write-Host ""

        # Check if pod-health-monitor exists
        $podExists = oc get deployment pod-health-monitor -n $Namespace 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[ERROR] pod-health-monitor deployment not found in $Namespace" -ForegroundColor Red
            exit 1
        }

        Write-Host "Recent logs (last 50 lines):" -ForegroundColor Yellow
        Write-Host ""
        oc logs deployment/pod-health-monitor -n $Namespace --tail=50

        Write-Host ""
        Write-Host "To follow logs in real-time:" -ForegroundColor Cyan
        Write-Host "  oc logs deployment/pod-health-monitor -n $Namespace -f" -ForegroundColor White
        Write-Host ""
    }

    "ApplyInCluster" {
        Write-Host "[INFO] Triggering in-cluster timeout application..." -ForegroundColor Cyan
        Write-Host ""

        # Check if utility script exists in cluster
        $utilityExists = oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "test -f /scripts/utils/apply-galera-timeouts.sh && echo yes || echo no" 2>&1

        if ($utilityExists -ne "yes") {
            Write-Host "[ERROR] Utility script not found in cluster" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Upload utilities first:" -ForegroundColor Yellow
            Write-Host "    .\manage-galera-utilities.ps1 -Namespace $Namespace -Action UploadUtilities" -ForegroundColor White
            Write-Host ""
            exit 1
        }

        # Build command
        $cmd = "/scripts/utils/apply-galera-timeouts.sh"

        if ($Profile) {
            $cmd += " --profile $Profile"
            Write-Host "  Profile: $Profile (explicit)" -ForegroundColor Gray
        } else {
            $cmd += " --auto-detect"
            Write-Host "  Profile: Auto-detect based on namespace/replicas" -ForegroundColor Gray
        }

        Write-Host "  Command: bash $cmd" -ForegroundColor Gray
        Write-Host ""

        Write-Host "[INFO] Executing in pod-health-monitor container..." -ForegroundColor Cyan
        Write-Host ""
        Write-Host "======================================================================" -ForegroundColor DarkGray

        # Execute in cluster
        oc exec deployment/pod-health-monitor -n $Namespace -- bash $cmd

        $exitCode = $LASTEXITCODE

        Write-Host "======================================================================" -ForegroundColor DarkGray
        Write-Host ""

        if ($exitCode -eq 0) {
            Write-Host "[SUCCESS] In-cluster timeout application completed" -ForegroundColor Green
            Write-Host ""
            Write-Host "Verify with:" -ForegroundColor Cyan
            Write-Host "  .\manage-galera-utilities.ps1 -Namespace $Namespace -Action Verify" -ForegroundColor White
        } else {
            Write-Host "[ERROR] In-cluster execution failed (exit code: $exitCode)" -ForegroundColor Red
            Write-Host ""
            Write-Host "Check logs:" -ForegroundColor Yellow
            Write-Host "  .\manage-galera-utilities.ps1 -Namespace $Namespace -Action ShowLogs" -ForegroundColor White
            exit $exitCode
        }

        Write-Host ""
    }
}

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
