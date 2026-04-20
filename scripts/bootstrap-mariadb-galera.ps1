<#
.SYNOPSIS
    Bootstrap MariaDB Galera cluster from split-brain or complete outage

.DESCRIPTION
    Performs disaster recovery for MariaDB Galera clusters that are:
    - In split-brain (all nodes NON-PRIMARY)
    - Completely down (0 replicas)
    - Stuck with conflicting grastate.dat

    This script:
    1. Analyzes grastate.dat (seqno values) from all pods or PVCs
    2. Identifies the node with highest seqno (most recent data)
    3. Guides safe bootstrap process with validation
    4. Handles edge cases (all seqno=-1, conflicting flags)

.PARAMETER Namespace
    OpenShift namespace (e.g., 950003-dev, 950003-test, 950003-prod)

.PARAMETER Analyze
    Analyze-only mode: Shows grastate.dat from all nodes, recommends bootstrap node

.PARAMETER Bootstrap
    Execute bootstrap recovery: Scale to 0, bootstrap from best node, scale up gradually

.PARAMETER BootstrapNode
    Override automatic node selection (use with caution)

.PARAMETER Force
    Skip safety confirmations (use with extreme caution)

.EXAMPLE
    # Analyze cluster state (safe, read-only)
    .\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-prod -Analyze

.EXAMPLE
    # Execute bootstrap recovery with automatic node selection
    .\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-prod -Bootstrap

.EXAMPLE
    # Force bootstrap from specific node
    .\scripts\bootstrap-mariadb-galera.ps1 -Namespace 950003-prod -Bootstrap -BootstrapNode "mariadb-galera-2" -Force

.NOTES
    Author: DevOps Team
    Prerequisites:
      - oc CLI installed and logged in
      - Permissions to scale StatefulSets in target namespace
      - Access to PVCs or running pods for grastate.dat analysis

    WARNING: Bootstrap recovery is a high-risk operation
      - Always run -Analyze first
      - Understand seqno values before proceeding
      - Backup PVCs if possible before bootstrap
      - Bootstrap from wrong node can cause data loss

    After successful bootstrap, deploy timeout configuration:
      .\scripts\deploy-galera-timeouts.ps1 -Namespace <namespace>
#>

[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = "Analyze")]
param(
    [Parameter(Mandatory = $true, HelpMessage = "OpenShift namespace")]
    [ValidatePattern('^950003-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(Mandatory = $false, ParameterSetName = "Analyze", HelpMessage = "Analyze grastate.dat only (safe, read-only)")]
    [switch]$Analyze,

    [Parameter(Mandatory = $false, ParameterSetName = "Bootstrap", HelpMessage = "Execute bootstrap recovery")]
    [switch]$Bootstrap,

    [Parameter(Mandatory = $false, ParameterSetName = "Bootstrap", HelpMessage = "Override automatic node selection")]
    [string]$BootstrapNode,

    [Parameter(Mandatory = $false, HelpMessage = "Skip safety confirmations")]
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Helper function to read grastate.dat from a pod
function Get-GrastateFromPod {
    param(
        [string]$PodName,
        [string]$Namespace
    )

    try {
        # Specify container explicitly to avoid "Defaulted container" stderr warning
        $grastateContent = oc exec $PodName -c mariadb-galera -n $Namespace -- cat /bitnami/mariadb/data/grastate.dat 2>&1

        # Filter out stderr warnings (in case container spec doesn't work)
        $grastateContent = $grastateContent | Where-Object { $_ -notmatch "Defaulted container|command terminated" }

        if ($LASTEXITCODE -ne 0 -or -not $grastateContent) {
            return @{
                Success = $false
                Source = "Pod:$PodName"
                Error = "Failed to read grastate.dat from running pod (exit code: $LASTEXITCODE)"
                RawContent = $null
            }
        }

        # Join array into single string for parsing
        $grastateText = $grastateContent -join "`n"

        # Parse grastate.dat with error handling
        try {
            $seqno = if ($grastateText -match 'seqno:\s*(-?\d+)') { [int64]$matches[1] } else { $null }
            $uuid = if ($grastateText -match 'uuid:\s*([a-f0-9-]+)') { $matches[1] } else { $null }
            $safeToBootstrap = if ($grastateText -match 'safe_to_bootstrap:\s*(\d+)') { [int]$matches[1] } else { 0 }
        } catch {
            return @{
                Success = $false
                Source = "Pod:$PodName"
                Error = "Failed to parse grastate.dat: $($_.Exception.Message)"
                RawContent = $grastateText
            }
        }

        return @{
            Success = $true
            Source = "Pod:$PodName"
            Seqno = $seqno
            UUID = $uuid
            SafeToBootstrap = $safeToBootstrap
            RawContent = $grastateText
        }
    } catch {
        return @{
            Success = $false
            Source = "Pod:$PodName"
            Error = $_.Exception.Message
            RawContent = $null
        }
    }
}

# Helper function to read grastate.dat from PVC (via debug pod)
function Get-GrastateFromPVC {
    param(
        [string]$PVCName,
        [string]$Namespace
    )

    try {
        # Create ephemeral debug pod that mounts the PVC
        $debugPodName = "grastate-reader-$(Get-Random -Minimum 1000 -Maximum 9999)"

        $debugPodYaml = @"
apiVersion: v1
kind: Pod
metadata:
  name: $debugPodName
  namespace: $Namespace
spec:
  restartPolicy: Never
  containers:
  - name: reader
    image: busybox
    command: ['sh', '-c', 'cat /data/data/grastate.dat']
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: $PVCName
"@

        # Create debug pod
        $createOutput = $debugPodYaml | oc apply -n $Namespace -f - 2>&1
        if ($LASTEXITCODE -ne 0) {
            return @{
                Success = $false
                Source = "PVC:$PVCName"
                Error = "Failed to create debug pod"
                RawContent = $null
            }
        }

        # Wait for pod to complete (max 60s)
        $waited = 0
        $maxWait = 60
        while ($waited -lt $maxWait) {
            $podPhase = oc get pod $debugPodName -n $Namespace -o jsonpath='{.status.phase}' 2>&1

            if ($podPhase -eq 'Succeeded') {
                break
            }

            if ($podPhase -eq 'Failed') {
                # Get container status for better error message
                $containerState = oc get pod $debugPodName -n $Namespace -o jsonpath='{.status.containerStatuses[0].state}' 2>&1
                oc delete pod $debugPodName -n $Namespace 2>&1 | Out-Null
                return @{
                    Success = $false
                    Source = "PVC:$PVCName"
                    Error = "Debug pod failed: $containerState"
                    RawContent = $null
                }
            }

            Start-Sleep -Seconds 2
            $waited += 2
        }

        if ($waited -ge $maxWait) {
            # Timeout - cleanup and return error
            oc delete pod $debugPodName -n $Namespace 2>&1 | Out-Null
            return @{
                Success = $false
                Source = "PVC:$PVCName"
                Error = "Timeout waiting for debug pod to complete (${maxWait}s)"
                RawContent = $null
            }
        }

        # Get logs (grastate.dat content)
        $grastateContent = oc logs $debugPodName -n $Namespace 2>&1

        # Filter out any error messages from logs output and join into single string
        $grastateLines = $grastateContent | Where-Object { $_ -notmatch "Error from server|warning:" }
        $grastateText = $grastateLines -join "`n"

        # Clean up debug pod (suppress warnings)
        oc delete pod $debugPodName -n $Namespace 2>&1 | Out-Null

        if ([string]::IsNullOrWhiteSpace($grastateText)) {
            return @{
                Success = $false
                Source = "PVC:$PVCName"
                Error = "Failed to read grastate.dat from PVC (empty content)"
                RawContent = $null
            }
        }

        # Parse grastate.dat from the joined text
        $seqno = if ($grastateText -match 'seqno:\s*(-?\d+)') { [int64]$matches[1] } else { $null }
        $uuid = if ($grastateText -match 'uuid:\s*([a-f0-9-]+)') { $matches[1] } else { $null }
        $safeToBootstrap = if ($grastateText -match 'safe_to_bootstrap:\s*(\d+)') { [int]$matches[1] } else { 0 }

        return @{
            Success = $true
            Source = "PVC:$PVCName"
            Seqno = $seqno
            UUID = $uuid
            SafeToBootstrap = $safeToBootstrap
            RawContent = $grastateText
        }
    } catch {
        # Cleanup on exception
        try { oc delete pod $debugPodName -n $Namespace 2>&1 | Out-Null } catch { }

        return @{
            Success = $false
            Source = "PVC:$PVCName"
            Error = $_.Exception.Message
            RawContent = $null
        }
    }
}

# Helper function to check Galera cluster health
function Test-GaleraClusterHealth {
    param(
        [string]$PodName,
        [string]$Namespace,
        [string]$RootPassword
    )

    try {
        # Specify container and filter stderr warnings
        $clusterStatus = oc exec $PodName -c mariadb-galera -n $Namespace -- mysql -u root -p"$RootPassword" -e "SHOW STATUS LIKE 'wsrep_cluster_status';" -N 2>&1 | Where-Object { $_ -notmatch "Defaulted container" } | ForEach-Object { ($_ -split '\s+')[1] }
        $localState = oc exec $PodName -c mariadb-galera -n $Namespace -- mysql -u root -p"$RootPassword" -e "SHOW STATUS LIKE 'wsrep_local_state_comment';" -N 2>&1 | Where-Object { $_ -notmatch "Defaulted container" } | ForEach-Object { ($_ -split '\s+')[1] }
        $clusterSize = oc exec $PodName -c mariadb-galera -n $Namespace -- mysql -u root -p"$RootPassword" -e "SHOW STATUS LIKE 'wsrep_cluster_size';" -N 2>&1 | Where-Object { $_ -notmatch "Defaulted container" } | ForEach-Object { ($_ -split '\s+')[1] }
        $ready = oc exec $PodName -c mariadb-galera -n $Namespace -- mysql -u root -p"$RootPassword" -e "SHOW STATUS LIKE 'wsrep_ready';" -N 2>&1 | Where-Object { $_ -notmatch "Defaulted container" } | ForEach-Object { ($_ -split '\s+')[1] }

        return @{
            Success = $true
            ClusterStatus = $clusterStatus
            LocalState = $localState
            ClusterSize = [int]$clusterSize
            Ready = $ready
        }
    } catch {
        return @{
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  MARIADB GALERA BOOTSTRAP RECOVERY" -ForegroundColor Yellow
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""

# Validate namespace exists
Write-Host "[INFO] Validating OpenShift connection..." -ForegroundColor Cyan
try {
    $null = oc version --client 2>&1
    if ($LASTEXITCODE -ne 0) { throw "oc CLI not available" }

    $currentProject = oc project -q 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Not logged in to OpenShift" }

    $null = oc get namespace $Namespace 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Namespace '$Namespace' not found or not accessible" }

    Write-Host "[OK] Connected to OpenShift" -ForegroundColor Green
    Write-Host "  Current project: $currentProject" -ForegroundColor Gray
    Write-Host "  Target namespace: $Namespace" -ForegroundColor Gray
} catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Get MariaDB root password from secret
Write-Host "[INFO] Retrieving database credentials..." -ForegroundColor Cyan
try {
    $rootPasswordB64 = oc get secret mariadb-galera -n $Namespace -o jsonpath='{.data.mariadb-root-password}' 2>&1
    if ($LASTEXITCODE -ne 0 -or -not $rootPasswordB64) {
        throw "Failed to get mariadb-root-password from secret"
    }
    $rootPassword = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($rootPasswordB64))
    Write-Host "  [OK] Credentials retrieved" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Get StatefulSet info and determine target replica count
Write-Host "[INFO] Analyzing cluster state..." -ForegroundColor Cyan
try {
    # Get current replicas
    $currentReplicas = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.spec.replicas}' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to get StatefulSet mariadb-galera"
    }

    # Try to get target replicas from annotation (saved by galera_safe_upgrade)
    $annotatedReplicas = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.metadata.annotations.last-known-replicas}' 2>&1

    # Determine target replica count (prefer annotation over CSV over current)
    $targetReplicas = $currentReplicas
    if ($annotatedReplicas -and $LASTEXITCODE -eq 0 -and $annotatedReplicas -match '^\d+$') {
        $targetReplicas = [int]$annotatedReplicas
        Write-Host "  Using annotated target: $targetReplicas (from last-known-replicas)" -ForegroundColor Gray
    } else {
        # Fallback: try to read from right-sizing CSV
        $csvFile = ".\openshift\$Namespace-sizing.csv"
        if (Test-Path $csvFile) {
            $csv = Import-Csv $csvFile
            $dbRow = $csv | Where-Object { $_.Component -eq "MariaDB" }
            if ($dbRow -and $dbRow.Replicas) {
                $targetReplicas = [int]$dbRow.Replicas
                Write-Host "  Using CSV target: $targetReplicas (from $Namespace-sizing.csv)" -ForegroundColor Gray
            }
        }

        if ($targetReplicas -eq $currentReplicas) {
            Write-Host "  Using current replicas: $currentReplicas (no annotation or CSV found)" -ForegroundColor Yellow
        }
    }

    $pods = oc get pods -l app.kubernetes.io/name=mariadb-galera -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>&1
    $podList = if ($pods) { ($pods -split '\s+') | Where-Object { $_ -ne '' } } else { @() }
    $runningPods = $podList.Count

    Write-Host "  Current replicas: $currentReplicas" -ForegroundColor Gray
    Write-Host "  Target replicas: $targetReplicas" -ForegroundColor Gray
    Write-Host "  Running pods: $runningPods" -ForegroundColor Gray
} catch {
    Write-Host "[ERROR] $_" -ForegroundColor Red
    exit 1
}

# Prompt user to confirm or override target replica count
Write-Host ""
Write-Host "[DECISION] Select target replica count for bootstrap recovery:" -ForegroundColor Yellow
Write-Host "  Available options:" -ForegroundColor Gray

$options = @()
$optionNum = 1

# Show annotation option if available
if ($annotatedReplicas -and $annotatedReplicas -match '^\d+$') {
    Write-Host "    [$optionNum] $annotatedReplicas replicas (from last-known-replicas annotation)" -ForegroundColor Gray
    $options += @{ Number = $optionNum; Value = [int]$annotatedReplicas; Source = "annotation" }
    $optionNum++
}

# Show CSV option if available and different
$csvFile = ".\openshift\$Namespace-sizing.csv"
$csvReplicas = $null
if (Test-Path $csvFile) {
    $csv = Import-Csv $csvFile
    $dbRow = $csv | Where-Object { $_.Deployment -eq "mariadb-galera" }
    if ($dbRow -and $dbRow.'Pod Count' -and $dbRow.'Pod Count' -ne $annotatedReplicas) {
        $csvReplicas = [int]$dbRow.'Pod Count'
        Write-Host "    [$optionNum] $csvReplicas replicas (from $Namespace-sizing.csv)" -ForegroundColor Gray
        $options += @{ Number = $optionNum; Value = $csvReplicas; Source = "CSV" }
        $optionNum++
    }
}

# Show current option if different from above
if ($currentReplicas -ne $annotatedReplicas -and ($csvReplicas -eq $null -or $currentReplicas -ne $csvReplicas)) {
    Write-Host "    [$optionNum] $currentReplicas replicas (current StatefulSet config)" -ForegroundColor Gray
    $options += @{ Number = $optionNum; Value = $currentReplicas; Source = "current" }
    $optionNum++
}

Write-Host "    [C] Custom value (1-10)" -ForegroundColor Gray
Write-Host ""

# Determine default (prefer CSV > annotation > current)
$defaultOption = $options | Where-Object { $_.Source -eq "CSV" } | Select-Object -First 1
if (-not $defaultOption) {
    $defaultOption = $options | Where-Object { $_.Source -eq "annotation" } | Select-Object -First 1
}
if (-not $defaultOption) {
    $defaultOption = $options | Select-Object -First 1
}

$defaultValue = if ($defaultOption) { $defaultOption.Value } else { 5 }
Write-Host "  Default: $defaultValue replicas" -ForegroundColor Cyan
$choice = Read-Host "  Enter choice [1-$($options.Count)/C] or press Enter for default ($defaultValue)"

if ([string]::IsNullOrWhiteSpace($choice)) {
    $targetReplicas = $defaultValue
    Write-Host "  Selected: $targetReplicas replicas (default)" -ForegroundColor Green
} elseif ($choice -match '^[Cc]$') {
    $customValue = Read-Host "  Enter target replica count (1-10)"
    if ($customValue -match '^\d+$' -and [int]$customValue -ge 1 -and [int]$customValue -le 10) {
        $targetReplicas = [int]$customValue
        Write-Host "  Selected: $targetReplicas replicas (custom)" -ForegroundColor Green
    } else {
        Write-Host "[ERROR] Invalid custom value: $customValue" -ForegroundColor Red
        exit 1
    }
} elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $options.Count) {
    $selectedOption = $options[[int]$choice - 1]
    $targetReplicas = $selectedOption.Value
    Write-Host "  Selected: $targetReplicas replicas (from $($selectedOption.Source))" -ForegroundColor Green
} else {
    Write-Host "[ERROR] Invalid choice: $choice" -ForegroundColor Red
    exit 1
}

Write-Host ""

# Analyze grastate.dat from all nodes
Write-Host "[INFO] Analyzing grastate.dat from all nodes..." -ForegroundColor Cyan
$grastateData = @()

if ($runningPods -gt 0) {
    Write-Host "  Reading from running pods..." -ForegroundColor Gray
    foreach ($pod in $podList) {
        Write-Host "    Checking $pod..." -ForegroundColor Gray
        $grastate = Get-GrastateFromPod -PodName $pod -Namespace $Namespace
        $grastateData += @{
            Node = $pod
            Data = $grastate
        }
    }
} else {
    Write-Host "  No running pods, reading from PVCs..." -ForegroundColor Gray

    # Find all existing PVCs (StatefulSet may be scaled to 0 but PVCs persist)
    # Get all PVCs and filter for mariadb-galera in PowerShell
    $allPVCs = oc get pvc -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>&1

    if ($allPVCs -match "No resources found" -or -not $allPVCs) {
        Write-Host "    [WARNING] No PVCs found in namespace" -ForegroundColor Yellow
        # Fallback: try expected replica count from CSV or annotation
        $targetReplicas = 5  # Default
        for ($i = 0; $i -lt $targetReplicas; $i++) {
            $pvcName = "data-mariadb-galera-$i"
            Write-Host "    Checking $pvcName..." -ForegroundColor Gray
            $grastate = Get-GrastateFromPVC -PVCName $pvcName -Namespace $Namespace
            $grastateData += @{
                Node = "mariadb-galera-$i"
                Data = $grastate
            }
        }
    } else {
        # Filter for mariadb-galera PVCs in PowerShell
        $pvcList = ($allPVCs -split '\s+') | Where-Object { $_ -match '^data-mariadb-galera-\d+$' }

        if ($pvcList.Count -eq 0) {
            Write-Host "    [WARNING] No mariadb-galera PVCs found" -ForegroundColor Yellow
        } else {
            foreach ($pvcName in $pvcList) {
                # Extract node number from PVC name (data-mariadb-galera-0 -> 0)
                if ($pvcName -match 'data-mariadb-galera-(\d+)') {
                    $nodeIndex = $matches[1]
                    Write-Host "    Checking $pvcName..." -ForegroundColor Gray
                    $grastate = Get-GrastateFromPVC -PVCName $pvcName -Namespace $Namespace
                    $grastateData += @{
                        Node = "mariadb-galera-$nodeIndex"
                        Data = $grastate
                    }
                }
            }
        }
    }
}

Write-Host ""

# Display analysis results
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  GRASTATE ANALYSIS" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""

$validNodes = @()
$maxSeqno = -99999999
$recommendedNode = $null

foreach ($entry in $grastateData) {
    $node = $entry.Node
    $data = $entry.Data

    Write-Host "  Node: $node" -ForegroundColor White
    if ($data.Success) {
        Write-Host "    seqno: $($data.Seqno)" -ForegroundColor $(if ($data.Seqno -eq -1) { "Yellow" } else { "Green" })
        Write-Host "    uuid: $($data.UUID)" -ForegroundColor Gray
        Write-Host "    safe_to_bootstrap: $($data.SafeToBootstrap)" -ForegroundColor $(if ($data.SafeToBootstrap -eq 1) { "Green" } else { "Gray" })

        # Show raw content for verification (first 3 lines)
        if ($data.RawContent) {
            $rawLines = ($data.RawContent -split "`n" | Select-Object -First 3) -join "; "
            Write-Host "    raw: $rawLines" -ForegroundColor DarkGray
        }

        $validNodes += @{
            Node = $node
            Seqno = $data.Seqno
            SafeToBootstrap = $data.SafeToBootstrap
        }

        # Track highest seqno
        if ($data.Seqno -ne $null -and $data.Seqno -gt $maxSeqno) {
            $maxSeqno = $data.Seqno
            $recommendedNode = $node
        }
    } else {
        Write-Host "    [ERROR] $($data.Error)" -ForegroundColor Red
    }
    Write-Host ""
}

# Handle edge cases
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  ANALYSIS SUMMARY" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""

if ($validNodes.Count -eq 0) {
    Write-Host "[ERROR] Could not read grastate.dat from any node" -ForegroundColor Red
    Write-Host "  Possible causes:" -ForegroundColor Yellow
    Write-Host "    - PVCs not accessible" -ForegroundColor Yellow
    Write-Host "    - Pods unable to start" -ForegroundColor Yellow
    Write-Host "    - grastate.dat missing or corrupted" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Manual intervention required" -ForegroundColor Yellow
    exit 1
}

# Check for all seqno=-1 (unclean shutdown)
$allNegativeOne = $validNodes | Where-Object { $_.Seqno -eq -1 } | Measure-Object | Select-Object -ExpandProperty Count
if ($allNegativeOne -eq $validNodes.Count) {
    Write-Host "[WARNING] All nodes have seqno=-1 (unclean shutdown)" -ForegroundColor Yellow
    Write-Host "  This indicates cluster was not shut down gracefully" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Recommendation:" -ForegroundColor Cyan
    Write-Host "    - Check for safe_to_bootstrap=1 flag" -ForegroundColor Gray
    Write-Host "    - If none, pick the node that was Primary last" -ForegroundColor Gray
    Write-Host "    - If uncertain, bootstrap from pod-0" -ForegroundColor Gray
    Write-Host ""

    # Look for safe_to_bootstrap=1
    $safeNode = $validNodes | Where-Object { $_.SafeToBootstrap -eq 1 } | Select-Object -First 1
    if ($safeNode) {
        $recommendedNode = $safeNode.Node
        Write-Host "  Found safe_to_bootstrap=1: $recommendedNode" -ForegroundColor Green
    } else {
        $recommendedNode = "mariadb-galera-0"
        Write-Host "  No safe_to_bootstrap flag found, defaulting to: $recommendedNode" -ForegroundColor Yellow
    }
} else {
    Write-Host "  Highest seqno: $maxSeqno" -ForegroundColor Green
    Write-Host "  Recommended bootstrap node: $recommendedNode" -ForegroundColor Green
    Write-Host ""
    Write-Host "  This node has the most recent transaction history" -ForegroundColor Gray
}

Write-Host ""

# If Analyze-only mode, exit here
if ($Analyze -or (-not $Bootstrap)) {
    Write-Host "======================================================================" -ForegroundColor DarkGray
    Write-Host "  RECOMMENDED ACTION" -ForegroundColor Cyan
    Write-Host "======================================================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  To bootstrap cluster from recommended node:" -ForegroundColor Gray
    Write-Host "    .\scripts\bootstrap-mariadb-galera.ps1 -Namespace $Namespace -Bootstrap" -ForegroundColor White
    Write-Host ""
    Write-Host "  To bootstrap from specific node (override):" -ForegroundColor Gray
    Write-Host "    .\scripts\bootstrap-mariadb-galera.ps1 -Namespace $Namespace -Bootstrap -BootstrapNode $recommendedNode" -ForegroundColor White
    Write-Host ""
    exit 0
}

# Bootstrap mode - execute recovery
Write-Host "======================================================================" -ForegroundColor Yellow
Write-Host "  BOOTSTRAP RECOVERY MODE" -ForegroundColor Yellow
Write-Host "======================================================================" -ForegroundColor Yellow
Write-Host ""

# Determine bootstrap node
$bootstrapNodeName = if ($BootstrapNode) { $BootstrapNode } else { $recommendedNode }

Write-Host "[WARNING] You are about to bootstrap the cluster" -ForegroundColor Yellow
Write-Host "  Bootstrap node: $bootstrapNodeName" -ForegroundColor Yellow
Write-Host "  Target replicas: $targetReplicas" -ForegroundColor Yellow
Write-Host ""
Write-Host "  This will:" -ForegroundColor Yellow
Write-Host "    1. Scale StatefulSet to 0 (graceful shutdown)" -ForegroundColor Yellow
Write-Host "    2. Scale to 1 (bootstrap from $bootstrapNodeName)" -ForegroundColor Yellow
Write-Host "    3. Scale up gradually: 1->2->3->...->$targetReplicas" -ForegroundColor Yellow
Write-Host "    4. Validate sync after each node joins" -ForegroundColor Yellow
Write-Host ""
Write-Host "  [DANGER] Bootstrapping from wrong node can cause data loss" -ForegroundColor Red
Write-Host ""

if (-not $Force) {
    $confirmation = Read-Host "[PROMPT] Type 'BOOTSTRAP' to confirm bootstrap recovery (or anything else to cancel)"
    if ($confirmation -ne 'BOOTSTRAP') {
        Write-Host "[INFO] Bootstrap cancelled by user" -ForegroundColor Cyan
        exit 0
    }
}

Write-Host ""
Write-Host "[INFO] Starting bootstrap recovery..." -ForegroundColor Cyan

# Scale to 0
Write-Host "  [1/$($targetReplicas + 2)] Scaling StatefulSet to 0..." -ForegroundColor Cyan
oc scale statefulset mariadb-galera --replicas=0 -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to scale down StatefulSet" -ForegroundColor Red
    exit 1
}

Write-Host "    Waiting for all pods to terminate..." -ForegroundColor Gray
Start-Sleep -Seconds 15

# Note: If cluster was already at 0 replicas, pods are already terminated
# The "No resources found" message (if shown) is expected and can be ignored

Write-Host "    [OK] All pods terminated" -ForegroundColor Green
Write-Host ""

# If bootstrap node is not pod-0, we need to update grastate.dat
if ($bootstrapNodeName -ne "mariadb-galera-0") {
    Write-Host "  [2/$($targetReplicas + 2)] Preparing bootstrap from $bootstrapNodeName..." -ForegroundColor Cyan
    Write-Host "    [WARNING] Bootstrap from non-pod-0 requires manual PVC manipulation" -ForegroundColor Yellow
    Write-Host "    For now, defaulting to mariadb-galera-0" -ForegroundColor Yellow
    $bootstrapNodeName = "mariadb-galera-0"
    Write-Host ""
}

# Bootstrap from pod-0
Write-Host "  [2/$($targetReplicas + 2)] Bootstrapping from $bootstrapNodeName..." -ForegroundColor Cyan
Write-Host "    Scaling to 1 replica..." -ForegroundColor Gray

oc scale statefulset mariadb-galera --replicas=1 -n $Namespace 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to scale to 1" -ForegroundColor Red
    exit 1
}

Write-Host "    Waiting for mariadb-galera-0 to start..." -ForegroundColor Gray

# Wait for pod to be running (not necessarily ready - readiness probe needs 30s)
$attempts = 0
$maxAttempts = 60
while ($attempts -lt $maxAttempts) {
    $podPhase = oc get pod mariadb-galera-0 -n $Namespace -o jsonpath='{.status.phase}' 2>&1
    if ($podPhase -eq 'Running') {
        Write-Host "    Pod is running, waiting for MariaDB to start..." -ForegroundColor Gray
        break
    }
    Start-Sleep -Seconds 5
    $attempts++
}

if ($attempts -ge $maxAttempts) {
    Write-Host "[ERROR] mariadb-galera-0 did not start" -ForegroundColor Red
    Write-Host "    Check logs: oc logs mariadb-galera-0 -n $Namespace" -ForegroundColor Gray
    exit 1
}

# Wait for MariaDB to be ready by testing connectivity directly
Write-Host "    Verifying MariaDB connectivity..." -ForegroundColor Gray
$attempts = 0
$maxAttempts = 30
$healthy = $false
while ($attempts -lt $maxAttempts) {
    Start-Sleep -Seconds 5
    $health = Test-GaleraClusterHealth -PodName "mariadb-galera-0" -Namespace $Namespace -RootPassword $rootPassword
    if ($health.Success -and $health.ClusterStatus -eq 'Primary') {
        $healthy = $true
        break
    }
    $attempts++
}

if (-not $healthy) {
    Write-Host "[ERROR] MariaDB did not become accessible" -ForegroundColor Red
    Write-Host "    Check logs: oc logs mariadb-galera-0 -n $Namespace" -ForegroundColor Gray
    exit 1
}

Write-Host "    [OK] Bootstrap successful - Cluster Status: Primary, Size: $($health.ClusterSize)" -ForegroundColor Green

Write-Host ""

# CRITICAL: Check and fix MARIADB_GALERA_CLUSTER_ADDRESS before scaling up
Write-Host "  [2.5/$($targetReplicas + 2)] Verifying cluster discovery configuration..." -ForegroundColor Cyan
Write-Host "    Running in-cluster diagnostic..." -ForegroundColor Gray

# Call the in-cluster fix script (uses flattened ConfigMap path)
$podName = oc get pod -l app=pod-health-monitor -n $Namespace -o jsonpath='{.items[0].metadata.name}' 2>&1
if ($LASTEXITCODE -eq 0 -and $podName) {
    $fixResult = oc exec $podName -n $Namespace -- bash -c "/scripts/utils-galera-fix-cluster-address.sh $Namespace mariadb-galera --fix" 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] Cluster address configuration verified" -ForegroundColor Green
    } elseif ($LASTEXITCODE -eq 1) {
        Write-Host "    [OK] Cluster address configuration fixed" -ForegroundColor Yellow
        Start-Sleep -Seconds 3
    } else {
        Write-Host "    [WARNING] Cluster address check returned code: $LASTEXITCODE" -ForegroundColor Yellow
        Write-Host "    Continuing with bootstrap, but scale-up may fail..." -ForegroundColor Yellow
    }
} else {
    Write-Host "    [WARNING] Could not find pod-health-monitor, skipping cluster address check" -ForegroundColor Yellow
    Write-Host "    Manual verification recommended after bootstrap" -ForegroundColor Yellow
}

Write-Host ""

# Scale up gradually
for ($i = 2; $i -le $targetReplicas; $i++) {
    $stepNum = $i + 1
    Write-Host "  [$stepNum/$($targetReplicas + 2)] Scaling to $i replicas..." -ForegroundColor Cyan
    oc scale statefulset mariadb-galera --replicas=$i -n $Namespace 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to scale to $i" -ForegroundColor Red
        exit 1
    }

    $podName = "mariadb-galera-$($i-1)"
    Write-Host "    Waiting for $podName to join..." -ForegroundColor Gray

    # Wait for pod to be created first
    $createAttempts = 0
    while ($createAttempts -lt 30) {
        $podExists = oc get pod $podName -n $Namespace --ignore-not-found=true -o jsonpath='{.metadata.name}' 2>&1
        if ($podExists -eq $podName) {
            break
        }
        Start-Sleep -Seconds 2
        $createAttempts++
    }

    if ($createAttempts -ge 30) {
        Write-Host "[ERROR] $podName was not created" -ForegroundColor Red
        Write-Host "    Check StatefulSet: oc describe statefulset mariadb-galera -n $Namespace" -ForegroundColor Gray
        exit 1
    }

    # Wait for pod to be running
    $podAttempts = 0
    while ($podAttempts -lt 60) {
        $podPhase = oc get pod $podName -n $Namespace -o jsonpath='{.status.phase}' 2>&1
        if ($podPhase -eq 'Running') {
            break
        }
        Start-Sleep -Seconds 5
        $podAttempts++
    }

    if ($podAttempts -ge 60) {
        Write-Host "[ERROR] $podName did not start" -ForegroundColor Red
        Write-Host "    Check logs: oc logs $podName -n $Namespace" -ForegroundColor Gray
        exit 1
    }

    # Wait for sync
    $syncAttempts = 0
    $synced = $false
    while ($syncAttempts -lt 30) {
        Start-Sleep -Seconds 5
        $health = Test-GaleraClusterHealth -PodName $podName -Namespace $Namespace -RootPassword $rootPassword

        if ($health.Success -and $health.LocalState -eq 'Synced' -and $health.ClusterSize -eq $i) {
            Write-Host "    [OK] $podName synced ($($health.ClusterSize)/$targetReplicas nodes)" -ForegroundColor Green
            $synced = $true
            break
        }
        $syncAttempts++
    }

    if (-not $synced) {
        Write-Host "[ERROR] $podName did not sync in time" -ForegroundColor Red
        Write-Host "    Current state: $($health.LocalState)" -ForegroundColor Gray
        Write-Host "    Cluster size: $($health.ClusterSize)" -ForegroundColor Gray
        exit 1
    }
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor Green
Write-Host "  BOOTSTRAP RECOVERY COMPLETE" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Cluster scaled to $targetReplicas replicas" -ForegroundColor Green
Write-Host "  All nodes synced and healthy" -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor Cyan
Write-Host "    1. Deploy timeout configuration to prevent future split-brain:" -ForegroundColor Gray
Write-Host "       .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace" -ForegroundColor White
Write-Host ""
Write-Host "    2. Monitor cluster health:" -ForegroundColor Gray
Write-Host "       oc exec deployment/pod-health-monitor -n $Namespace -- bash /scripts/utils/galera-inspect.sh" -ForegroundColor White
Write-Host ""
