# =============================================================================
# GALERA RECOVERY - STEP-BY-STEP EXECUTION
# =============================================================================
# Purpose: Run individual galera_safe_upgrade steps for debugging/validation.
#          Executes directly in pod-health-monitor via oc exec (no deployment restart).
#
# Usage:
#   .\scripts\galera-recovery-step.ps1 -Step 7                # Run only step 7
#   .\scripts\galera-recovery-step.ps1 -FromStep 7            # Run steps 7 → end
#   .\scripts\galera-recovery-step.ps1 -FromStep 7 -ToStep 8  # Run steps 7-8
#   .\scripts\galera-recovery-step.ps1 -Status                # Show cluster state
#   .\scripts\galera-recovery-step.ps1 -Full                  # Run all steps (full recovery)
#
# Steps:
#   1 = Pre-flight check + save annotation
#   2 = Scale to 0 + clear bad env vars
#   3 = Delete secondary PVCs + fix grastate.dat
#   4 = Enable bootstrap env vars
#   5 = Scale to 1 + wait for galera-0 Ready (includes pc.recovery fallback)
#   7 = Set partition=1, disable bootstrap, verify galera-0 Primary
#   8 = Scale to target + NON-PRIMARY deadlock detection
#   9 = Wait for sync + remove partition + final health check
#
# Related:
#   - openshift/scripts/utils/database.sh (galera_safe_upgrade)
#   - scripts/emergency-galera-recovery.ps1 (full automated recovery)
# =============================================================================

param(
    [Parameter(Mandatory=$false)]
    [ValidateSet('950003-dev', '950003-test', '950003-prod')]
    [string]$Namespace = '950003-test',

    [Parameter(Mandatory=$false)]
    [ValidateSet(1, 2, 3, 4, 5, 7, 8, 9)]
    [int]$Step = 0,

    [Parameter(Mandatory=$false)]
    [ValidateSet(1, 2, 3, 4, 5, 7, 8, 9)]
    [int]$FromStep = 0,

    [Parameter(Mandatory=$false)]
    [ValidateSet(1, 2, 3, 4, 5, 7, 8, 9)]
    [int]$ToStep = 0,

    [Parameter(Mandatory=$false)]
    [int]$TargetReplicas = 0,

    [Parameter(Mandatory=$false)]
    [switch]$Status,

    [Parameter(Mandatory=$false)]
    [switch]$Full,

    [Parameter(Mandatory=$false)]
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# ─── Step reference table ────────────────────────────────────────────────────
$stepTable = @(
    [PSCustomObject]@{ Step = 1; Phase = "Pre-flight"; Description = "Verify galera-0 safe + save annotation"; Precondition = "None" }
    [PSCustomObject]@{ Step = 2; Phase = "Teardown";   Description = "Scale to 0, clear EXTRA_FLAGS";          Precondition = "None" }
    [PSCustomObject]@{ Step = 3; Phase = "PVC Prep";   Description = "Delete secondary PVCs, fix grastate.dat"; Precondition = "All pods terminated" }
    [PSCustomObject]@{ Step = 4; Phase = "Bootstrap";  Description = "Set bootstrap=yes env vars";             Precondition = "PVCs cleaned" }
    [PSCustomObject]@{ Step = 5; Phase = "Primary Up"; Description = "Scale to 1, wait galera-0 Ready";        Precondition = "Bootstrap env set" }
    [PSCustomObject]@{ Step = 7; Phase = "Partition";  Description = "Partition=1, bootstrap=no, verify Primary"; Precondition = "galera-0 Running/Primary" }
    [PSCustomObject]@{ Step = 8; Phase = "Scale Out";  Description = "Scale to target + deadlock detection";    Precondition = "Template updated, galera-0 Primary" }
    [PSCustomObject]@{ Step = 9; Phase = "Finalize";   Description = "Wait sync, remove partition, health check"; Precondition = "All pods running" }
)

# ─── Helper: find pod-health-monitor pod ─────────────────────────────────────
function Get-MonitorPod {
    $pod = oc get pods -l app=pod-health-monitor -n $Namespace -o jsonpath='{.items[0].metadata.name}' 2>$null
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pod)) {
        Write-Host '[ERROR] pod-health-monitor not found in $Namespace' -ForegroundColor Red
        Write-Host "  Deploy it first: .\scripts\update-pod-health-scripts.ps1 -Namespace $Namespace" -ForegroundColor Gray
        exit 1
    }
    $podJson = oc get pod $pod -n $Namespace -o json 2>$null | ConvertFrom-Json
    $ready = ($podJson.status.conditions | Where-Object { $_.type -eq "Ready" }).status
    if ($ready -ne "True") {
        Write-Host "[WARN] pod-health-monitor exists ($pod) but not Ready" -ForegroundColor Yellow
    }
    return $pod
}

# ─── Helper: get cluster status snapshot ─────────────────────────────────────
function Show-ClusterStatus {
    Write-Host ""
    Write-Host "═════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  GALERA CLUSTER STATUS - $Namespace" -ForegroundColor Cyan
    Write-Host "═════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    # StatefulSet state
    Write-Host '[StatefulSet]' -ForegroundColor Yellow
    oc get statefulset mariadb-galera -n $Namespace -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,UPDATED:.status.updatedReplicas 2>$null

    # Parse StatefulSet JSON once (avoids jsonpath quoting issues on Windows)
    $stsJson = $null
    try {
        $stsJson = oc get statefulset mariadb-galera -n $Namespace -o json 2>$null | ConvertFrom-Json
    } catch {}

    # Partition
    $partition = if ($stsJson) { $stsJson.spec.updateStrategy.rollingUpdate.partition } else { $null }
    Write-Host "  Partition: $(if (-not $partition) { '0 (default)' } else { $partition })" -ForegroundColor $(if ($partition -gt 0) { 'Yellow' } else { 'Gray' })

    # Bootstrap env
    $bootstrap = if ($stsJson) { ($stsJson.spec.template.spec.containers[0].env | Where-Object { $_.name -eq 'MARIADB_GALERA_CLUSTER_BOOTSTRAP' }).value } else { $null }
    Write-Host "  Bootstrap: $(if ([string]::IsNullOrWhiteSpace($bootstrap)) { '<not set>' } else { $bootstrap })" -ForegroundColor $(if ($bootstrap -eq 'yes') { 'Red' } else { 'Gray' })

    # Extra flags
    $extraFlags = if ($stsJson) { ($stsJson.spec.template.spec.containers[0].env | Where-Object { $_.name -eq 'MARIADB_EXTRA_FLAGS' }).value } else { $null }
    if (-not [string]::IsNullOrWhiteSpace($extraFlags)) {
        Write-Host "  EXTRA_FLAGS: $extraFlags" -ForegroundColor Red
    }

    # MANUAL_MODE
    $manualMode = oc set env deployment/pod-health-monitor --list -n $Namespace 2>$null | Select-String '^MANUAL_MODE=' | ForEach-Object { $_.ToString().Split('=',2)[1] }
    Write-Host "  MANUAL_MODE: $(if ([string]::IsNullOrWhiteSpace($manualMode)) { 'false (default)' } else { $manualMode })" -ForegroundColor $(if ($manualMode -eq 'true') { 'Yellow' } else { 'Gray' })

    Write-Host ""
    Write-Host '[Pods]' -ForegroundColor Yellow
    # Derive label selector from StatefulSet spec.selector.matchLabels
    # (same approach as get_pods_for_resource() in openshift.sh — reads the
    # actual selector rather than guessing the label key/value)
    $labelSelector = ''
    if ($stsJson -and $stsJson.spec.selector.matchLabels) {
        $labelSelector = ($stsJson.spec.selector.matchLabels.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ','
    }
    if ([string]::IsNullOrWhiteSpace($labelSelector)) {
        $labelSelector = "app.kubernetes.io/name=mariadb-galera"   # fallback
    }
    Write-Host "  Selector: $labelSelector" -ForegroundColor Gray

    # Replicas may be 0 (failsafe mode) — "No resources found" is expected, not an error
    $ErrorActionPreference = 'SilentlyContinue'
    $podOutput = oc get pods -l $labelSelector -n $Namespace -o wide --no-headers 2>$null
    $ErrorActionPreference = 'Stop'
    if (-not $podOutput -or $podOutput -match 'No resources found') {
        Write-Host "  (none - StatefulSet scaled to 0)" -ForegroundColor Gray
    } elseif (-not [string]::IsNullOrWhiteSpace($podOutput)) {
        $podOutput | ForEach-Object { Write-Host $_ }
    }

    # wsrep status (if any pods running) — query via pod-health-monitor
    # which oc execs into galera pods (avoids PowerShell quoting issues entirely)
    $runningPods = oc get pods -l $labelSelector --field-selector=status.phase=Running -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>&1
    if (-not [string]::IsNullOrWhiteSpace($runningPods) -and $runningPods -notmatch 'No resources found') {
        Write-Host ""
        Write-Host '[Galera Status]' -ForegroundColor Yellow
        $monitorPod = oc get pods -l app=pod-health-monitor -n $Namespace -o jsonpath='{.items[0].metadata.name}' 2>$null
        if (-not [string]::IsNullOrWhiteSpace($monitorPod)) {
            foreach ($pod in $runningPods.Split(' ', [StringSplitOptions]::RemoveEmptyEntries)) {
                $wsrepScript = @"
oc exec $pod -c mariadb-galera -- bash -c 'pw=`$(cat "`$MARIADB_ROOT_PASSWORD_FILE"); mysql -u root -p"`$pw" -Nse "SHOW STATUS LIKE \"wsrep%\""' 2>/dev/null | grep -E "wsrep_cluster_status|wsrep_local_state_comment|wsrep_cluster_size"
"@
                $ErrorActionPreference = 'Continue'
                $wsrep = $wsrepScript | oc exec -i $monitorPod -n $Namespace -- bash 2>$null
                $ErrorActionPreference = 'Stop'
                if (-not [string]::IsNullOrWhiteSpace($wsrep)) {
                    $wsrepOneLine = ($wsrep -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ', '
                    Write-Host "  ${pod}: $wsrepOneLine" -ForegroundColor Gray
                } else {
                    Write-Host "  ${pod}: (MySQL unreachable)" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "  (pod-health-monitor not available for status query)" -ForegroundColor Yellow
        }
    }

    Write-Host ""
}

# ─── Mode: Status only ──────────────────────────────────────────────────────
if ($Status) {
    Show-ClusterStatus
    Write-Host "Step Reference:" -ForegroundColor Cyan
    $stepTable | Format-Table -AutoSize
    exit 0
}

# ─── Resolve step range ─────────────────────────────────────────────────────
if ($Full) {
    $FromStep = 1; $ToStep = 99
} elseif ($Step -gt 0) {
    $FromStep = $Step; $ToStep = $Step
} elseif ($FromStep -eq 0 -and $ToStep -eq 0) {
    Write-Host ""
    Write-Host "Usage: specify which step(s) to run" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  .\scripts\galera-recovery-step.ps1 -Step 7                # Run only step 7" -ForegroundColor Gray
    Write-Host "  .\scripts\galera-recovery-step.ps1 -FromStep 7            # Steps 7 -> end" -ForegroundColor Gray
    Write-Host "  .\scripts\galera-recovery-step.ps1 -FromStep 7 -ToStep 8  # Steps 7-8" -ForegroundColor Gray
    Write-Host "  .\scripts\galera-recovery-step.ps1 -Full                  # Full recovery" -ForegroundColor Gray
    Write-Host "  .\scripts\galera-recovery-step.ps1 -Status                # Cluster status" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Step Reference:" -ForegroundColor Cyan
    $stepTable | Format-Table -AutoSize
    exit 0
}

if ($FromStep -eq 0) { $FromStep = 1 }
if ($ToStep -eq 0) { $ToStep = 99 }

# ─── Show current state + confirm ───────────────────────────────────────────
Show-ClusterStatus

$stepsInRange = $stepTable | Where-Object { $_.Step -ge $FromStep -and $_.Step -le $ToStep }
Write-Host "Steps to execute:" -ForegroundColor Yellow
$stepsInRange | Format-Table -AutoSize

if (-not $Full -and $FromStep -gt 1) {
    Write-Host "[INFO] Starting from step $FromStep - ensure prior steps completed successfully" -ForegroundColor Yellow
    Write-Host ""
}

if (-not $Force) {
    $confirm = Read-Host "Proceed? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host '[ABORT] Cancelled' -ForegroundColor Yellow
        exit 0
    }
} else {
    Write-Host "[INFO] -Force specified, skipping confirmation" -ForegroundColor Gray
}

# ─── Find pod-health-monitor ────────────────────────────────────────────────
$monitorPod = Get-MonitorPod

# ─── Build exec command ─────────────────────────────────────────────────────
$envPrefix = "GALERA_FROM_STEP=$FromStep GALERA_TO_STEP=$ToStep"
if ($TargetReplicas -gt 0) {
    $envPrefix += " GALERA_TARGET_REPLICAS=$TargetReplicas"
}

$bashCommand = "$envPrefix source /scripts/repair-mariadb-galera.sh"

Write-Host ""
Write-Host "[EXEC] Running in pod-health-monitor ($monitorPod):" -ForegroundColor Cyan
Write-Host "  $bashCommand" -ForegroundColor Gray
Write-Host ""

# ─── Execute ────────────────────────────────────────────────────────────────
# oc exec may emit stderr warnings (e.g. token deprecation) that are not errors.
# Temporarily relax ErrorActionPreference so PowerShell doesn't abort on them.
$ErrorActionPreference = 'Continue'
oc exec $monitorPod -n $Namespace -- bash -c $bashCommand 2>&1 | ForEach-Object {
    if ($_ -is [System.Management.Automation.ErrorRecord]) {
        # Suppress known harmless warnings; surface genuine errors
        $msg = $_.ToString()
        if ($msg -notmatch 'TokenRequest|secret-based tokens') {
            Write-Host $msg -ForegroundColor Yellow
        }
    } else {
        Write-Host $_
    }
}
$exitCode = $LASTEXITCODE
$ErrorActionPreference = 'Stop'

Write-Host ""
if ($exitCode -eq 0) {
    Write-Host '[OK] Step(s) completed successfully' -ForegroundColor Green
} else {
    Write-Host "[FAIL] Step(s) failed (exit code: $exitCode)" -ForegroundColor Red
}

# ─── Show post-execution state ──────────────────────────────────────────────
Write-Host ""
Write-Host "Post-execution state:" -ForegroundColor Cyan
Show-ClusterStatus

# ─── Suggest next step ──────────────────────────────────────────────────────
if ($exitCode -eq 0 -and $ToStep -lt 99) {
    $nextSteps = $stepTable | Where-Object { $_.Step -gt $ToStep } | Select-Object -First 1
    if ($nextSteps) {
        Write-Host "Next step:" -ForegroundColor Yellow
        Write-Host "  .\scripts\galera-recovery-step.ps1 -Step $($nextSteps.Step) -Namespace $Namespace" -ForegroundColor Cyan
        Write-Host "  ($($nextSteps.Phase): $($nextSteps.Description))" -ForegroundColor Gray
        Write-Host ""
    }
}

exit $exitCode
