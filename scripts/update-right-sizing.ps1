<#
.SYNOPSIS
    Upload right-sizing CSV and my.cnf to cluster and trigger in-cluster execution

.DESCRIPTION
    This script manages right-sizing and database configuration as follows:
    1. Uploads CSV file to ConfigMap in OpenShift
    2. Uploads my.cnf to mariadb-galera-configuration ConfigMap (optional)
    3. Triggers pod-health-monitor to execute right-sizing script
    4. Applies CPU/memory limits, pod scaling, and Galera timeout configuration
    5. Returns execution output for review

    All heavy lifting happens IN the cluster - this script just orchestrates.

.PARAMETER Namespace
    Target OpenShift namespace (e.g., 950003-dev, 950003-test, 950003-prod)

.PARAMETER CSVPath
    Path to local right-sizing CSV file (default: auto-detect from namespace)

.PARAMETER MyCNF
    Path to my.cnf file to upload (default: auto-detect environment-specific or config/mariadb/my.cnf)
    Examples:
      - config/mariadb/950003-dev.cnf (environment-specific)
      - config/mariadb/my-test-PT30S.cnf (testing variation)
      - config/mariadb/my.cnf (default)

.PARAMETER Deployments
    Filter right-sizing to specific deployments (default: all)
    Examples:
      - "mariadb-galera" (single deployment)
      - "mariadb-galera","php","web" (multiple deployments)
      - $null (default - process all deployments)

.PARAMETER SkipMyCNF
    Skip my.cnf update (only apply right-sizing from CSV)

.PARAMETER DryRun
    Preview changes without applying them

.EXAMPLE
    # Auto-detect CSV and my.cnf from namespace
    .\scripts\update-right-sizing.ps1 -Namespace 950003-dev

.EXAMPLE
    # Test custom my.cnf configuration
    .\scripts\update-right-sizing.ps1 -Namespace 950003-dev -MyCNF config\mariadb\my-test-PT30S.cnf

.EXAMPLE
    # Only update resource sizing (skip my.cnf)
    .\scripts\update-right-sizing.ps1 -Namespace 950003-test -SkipMyCNF

.EXAMPLE
    # Only right-size MariaDB (don't touch other services)
    .\scripts\update-right-sizing.ps1 -Namespace 950003-prod -Deployments mariadb-galera

.EXAMPLE
    # Right-size multiple specific deployments
    .\scripts\update-right-sizing.ps1 -Namespace 950003-dev -Deployments mariadb-galera,php,web

.EXAMPLE
    # Preview changes without applying
    .\scripts\update-right-sizing.ps1 -Namespace 950003-prod -DryRun

.NOTES
    PHILOSOPHY: This script uploads configuration and triggers in-cluster automation.
    All resource management, pod restarts, and Galera tuning happen in pod-health-monitor.

    CSV Format (12 columns):
      Deployment, Type, Pod Count, Max Pods, PVC Count, PVC Capacity (MiB),
      CPU Request (m), CPU Limit (m), Mem. Request (MiB), Mem. Limit (MiB),
      CPU Scale Value, Galera Profile

    my.cnf Management:
      - Environment-specific: config/mariadb/<namespace>.cnf (auto-detected)
      - Default: config/mariadb/my.cnf
      - Testing: config/mariadb/my-test-<variation>.cnf (manual override)
      - Updates existing mariadb-galera-configuration ConfigMap (same as deployment)
      - Pods restart to pick up new configuration

    Integration with Deployment:
      - Uses same ConfigMap as deploy-mariadb-galera.sh
      - Changes persist through pod restarts
      - Commit working configs to repo for future deployments
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(Mandatory=$false)]
    [string]$CSVPath,

    [Parameter(Mandatory=$false)]
    [string]$MyCNF,

    [Parameter(Mandatory=$false)]
    [string[]]$Deployments,

    [Parameter(Mandatory=$false)]
    [switch]$SkipMyCNF,

    [Parameter(Mandatory=$false)]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  RIGHT-SIZING + GALERA TUNING ORCHESTRATOR" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Namespace: $Namespace" -ForegroundColor Gray
if ($DryRun) {
    Write-Host "  Mode: DRY-RUN (no changes will be applied)" -ForegroundColor Yellow
}
if ($Deployments) {
    Write-Host "  Filter: $($Deployments -join ', ')" -ForegroundColor Yellow
    Write-Host "  (Only these deployments will be processed)" -ForegroundColor Gray
}
Write-Host ""

# Validate OpenShift connection
try {
    $null = oc whoami 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Not logged in to OpenShift"
    }
    Write-Host "[OK] Connected to OpenShift" -ForegroundColor Green
} catch {
    Write-Host "[ERROR] OpenShift connection failed: $_" -ForegroundColor Red
    exit 1
}

# Auto-detect CSV path if not provided
if (-not $CSVPath) {
    $CSVPath = "openshift\$Namespace-sizing.csv"
    Write-Host "[INFO] Auto-detected CSV: $CSVPath" -ForegroundColor Cyan
}

# Validate CSV file exists
if (-not (Test-Path $CSVPath)) {
    Write-Host "[ERROR] CSV file not found: $CSVPath" -ForegroundColor Red
    exit 1
}

# Auto-detect my.cnf path if not provided (unless skipped)
$myCnfPath = $null
if (-not $SkipMyCNF) {
    if ($MyCNF) {
        # User specified custom my.cnf
        $myCnfPath = $MyCNF
        Write-Host "[INFO] Using custom my.cnf: $myCnfPath" -ForegroundColor Cyan
    } else {
        # Auto-detect: try environment-specific first, then default
        $envSpecificCnf = "config\mariadb\$Namespace.cnf"
        $defaultCnf = "config\mariadb\my.cnf"

        if (Test-Path $envSpecificCnf) {
            $myCnfPath = $envSpecificCnf
            Write-Host "[INFO] Auto-detected environment-specific my.cnf: $myCnfPath" -ForegroundColor Cyan
        } elseif (Test-Path $defaultCnf) {
            $myCnfPath = $defaultCnf
            Write-Host "[INFO] Using default my.cnf: $myCnfPath" -ForegroundColor Cyan
            Write-Host "  TIP: Create $envSpecificCnf for environment-specific configuration" -ForegroundColor Gray
        } else {
            Write-Host "[WARN] No my.cnf file found - skipping database configuration update" -ForegroundColor Yellow
            Write-Host "  Looked for: $envSpecificCnf or $defaultCnf" -ForegroundColor Gray
        }
    }

    # Validate my.cnf exists if we're supposed to use it
    if ($myCnfPath -and -not (Test-Path $myCnfPath)) {
        Write-Host "[ERROR] my.cnf file not found: $myCnfPath" -ForegroundColor Red
        exit 1
    }
} else {
    Write-Host "[INFO] Skipping my.cnf update (SkipMyCNF flag set)" -ForegroundColor Cyan
}

Write-Host "[INFO] Reading CSV file..." -ForegroundColor Cyan
$csvContent = Get-Content $CSVPath -Raw
$csvLines = $csvContent -split "`n" | Where-Object { $_.Trim() -ne "" }
Write-Host "  Rows: $($csvLines.Count) (including header)" -ForegroundColor Gray

if ($myCnfPath) {
    Write-Host "[INFO] Reading my.cnf file..." -ForegroundColor Cyan
    $myCnfContent = Get-Content $myCnfPath -Raw
    $myCnfLines = ($myCnfContent -split "`n").Count
    Write-Host "  Lines: $myCnfLines" -ForegroundColor Gray

    # Show [galera] section preview if it exists
    if ($myCnfContent -match '\[galera\]') {
        Write-Host "  Contains [galera] section with Galera-specific configuration" -ForegroundColor Gray
    }
}

Write-Host ""

# Parse CSV to show what will be applied
Write-Host "[INFO] Configuration to be applied:" -ForegroundColor Cyan
Write-Host ""

$csv = Import-Csv $CSVPath

# Apply deployment filter if specified
if ($Deployments) {
    $csv = $csv | Where-Object { $Deployments -contains $_.Deployment }
    if ($csv.Count -eq 0) {
        Write-Host "[ERROR] No deployments matched filter: $($Deployments -join ', ')" -ForegroundColor Red
        Write-Host "  Check deployment names in CSV file" -ForegroundColor Yellow
        exit 1
    }
}

$galeraDeployments = $csv | Where-Object { $_.'Galera Profile' -ne '' }

Write-Host "  Resource Sizing:" -ForegroundColor Yellow
foreach ($row in $csv) {
    $podCount = $row.'Pod Count'
    if ($podCount -gt 0) {
        $cpu = $row.'CPU Limit (m)'
        $mem = $row.'Mem. Limit (MiB)'
        Write-Host "    - $($row.Deployment): $podCount pods, CPU=${cpu}m, Mem=${mem}Mi" -ForegroundColor White
    }
}

Write-Host ""
Write-Host "  Galera Timeout Configuration:" -ForegroundColor Yellow
if ($galeraDeployments.Count -gt 0) {
    foreach ($row in $galeraDeployments) {
        Write-Host "    - $($row.Deployment): Profile '$($row.'Galera Profile')'" -ForegroundColor White
    }
} else {
    Write-Host "    (none configured)" -ForegroundColor Gray
}

Write-Host ""

if ($DryRun) {
    Write-Host "[DRY-RUN] Would perform the following actions:" -ForegroundColor Yellow
    Write-Host "  1. Upload CSV to ConfigMap: right-sizing-config" -ForegroundColor Gray
    if ($myCnfPath) {
        Write-Host "  2. Upload my.cnf to ConfigMap: mariadb-galera-configuration" -ForegroundColor Gray
        Write-Host "     Source: $myCnfPath" -ForegroundColor Gray
    }
    Write-Host "  3. Execute in pod-health-monitor: bash /scripts/right-sizing.sh" -ForegroundColor Gray
    Write-Host "  4. Apply resource limits and pod scaling" -ForegroundColor Gray
    if ($galeraDeployments.Count -gt 0) {
        Write-Host "  5. Apply Galera timeout configuration" -ForegroundColor Gray
    }
    if ($myCnfPath) {
        Write-Host "  6. Restart MariaDB pods to pick up new my.cnf configuration" -ForegroundColor Gray
    }
    Write-Host "  7. Verify cluster health" -ForegroundColor Gray
    Write-Host ""
    exit 0
}

# Note: CSV is already uploaded to openshift-resources ConfigMap at /openshift/{namespace}-sizing.csv
# via update-pod-health-scripts.ps1. No need to create separate right-sizing-config ConfigMap.
Write-Host "[INFO] Using CSV from openshift-resources ConfigMap..." -ForegroundColor Cyan
Write-Host "  Path in pod: /openshift/$Namespace-sizing.csv" -ForegroundColor Gray
Write-Host ""

# Upload my.cnf to mariadb-galera-configuration ConfigMap if provided
if ($myCnfPath) {
    Write-Host "[INFO] Uploading my.cnf to mariadb-galera-configuration ConfigMap..." -ForegroundColor Cyan

    # Check if ConfigMap exists
    $myCnfConfigMap = "mariadb-galera-configuration"
    $cmExists = oc get configmap $myCnfConfigMap -n $Namespace 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host "  ConfigMap exists, updating..." -ForegroundColor Gray

        # Delete and recreate to ensure clean update
        oc delete configmap $myCnfConfigMap -n $Namespace 2>&1 | Out-Null
    } else {
        Write-Host "  Creating new ConfigMap..." -ForegroundColor Gray
    }

    # Create ConfigMap from my.cnf file
    oc create configmap $myCnfConfigMap --from-file="my.cnf=$myCnfPath" -n $Namespace 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to create my.cnf ConfigMap" -ForegroundColor Red
        exit 1
    }

    # Add Helm labels/annotations (same as deploy-mariadb-galera.sh does)
    oc label configmap $myCnfConfigMap app.kubernetes.io/managed-by=Helm --overwrite -n $Namespace 2>&1 | Out-Null
    oc annotate configmap $myCnfConfigMap meta.helm.sh/release-name=mariadb-galera --overwrite -n $Namespace 2>&1 | Out-Null
    oc annotate configmap $myCnfConfigMap meta.helm.sh/release-namespace="$Namespace" --overwrite -n $Namespace 2>&1 | Out-Null

    Write-Host "[OK] my.cnf ConfigMap updated: $myCnfConfigMap" -ForegroundColor Green
    Write-Host "  Source: $myCnfPath" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  [NOTE] MariaDB pods will restart during right-sizing to pick up new configuration" -ForegroundColor Yellow
    Write-Host ""
}

# Check if pod-health-monitor exists and has right-sizing script
Write-Host "[INFO] Checking pod-health-monitor availability..." -ForegroundColor Cyan

$podExists = oc get deployment pod-health-monitor -n $Namespace 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] pod-health-monitor deployment not found in $Namespace" -ForegroundColor Red
    Write-Host "  Deploy pod-health-monitor first with right-sizing scripts" -ForegroundColor Yellow
    exit 1
}

# Verify right-sizing script exists in pod
$scriptCheck = oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "test -f /scripts/right-sizing.sh && echo exists || echo missing" 2>&1
if ($scriptCheck -ne "exists") {
    Write-Host "[ERROR] right-sizing.sh not found in pod-health-monitor" -ForegroundColor Red
    Write-Host "  Upload scripts first: .\manage-galera-utilities.ps1 -Action UploadUtilities" -ForegroundColor Yellow
    exit 1
}

Write-Host "[OK] pod-health-monitor ready" -ForegroundColor Green
Write-Host ""

# Execute right-sizing script in cluster
Write-Host "[INFO] Executing right-sizing in cluster..." -ForegroundColor Cyan
Write-Host "  This may take 5-10 minutes depending on cluster size" -ForegroundColor Gray
Write-Host ""
Write-Host "======================================================================" -ForegroundColor DarkGray

# Execute the script, passing namespace and deployment filter
# CSV is already mounted at /openshift/{namespace}-sizing.csv from openshift-resources ConfigMap
$execCommand = "export DEPLOY_NAMESPACE=$Namespace; export CSV_SOURCE=file"
if ($Deployments) {
    $deploymentFilter = $Deployments -join ','
    $execCommand += "; export DEPLOYMENT_FILTER='$deploymentFilter'"
}
$execCommand += "; bash /scripts/right-sizing.sh"

oc exec deployment/pod-health-monitor -n $Namespace -- bash -c $execCommand

$exitCode = $LASTEXITCODE

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""

if ($exitCode -eq 0) {
    Write-Host "[SUCCESS] Right-sizing completed successfully" -ForegroundColor Green
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Cyan
    Write-Host "  1. Verify pod status:" -ForegroundColor Gray
    Write-Host "     oc get pods -n $Namespace" -ForegroundColor White
    Write-Host ""
    Write-Host "  2. Check Galera cluster health:" -ForegroundColor Gray
    Write-Host "     oc exec deployment/pod-health-monitor -n $Namespace -- bash /scripts/galera-inspect.sh" -ForegroundColor White
    Write-Host ""
    Write-Host "  3. Monitor for split-brain (should not occur):" -ForegroundColor Gray
    Write-Host "     oc logs -l app.kubernetes.io/name=mariadb-galera -n $Namespace --tail=50 -f" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "[ERROR] Right-sizing failed (exit code: $exitCode)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Troubleshooting:" -ForegroundColor Yellow
    Write-Host "  1. Check pod-health-monitor logs:" -ForegroundColor Gray
    Write-Host "     oc logs deployment/pod-health-monitor -n $Namespace --tail=100" -ForegroundColor White
    Write-Host ""
    Write-Host "  2. Verify CSV exists in pod:" -ForegroundColor Gray
    Write-Host "     oc exec deployment/pod-health-monitor -n $Namespace -- cat /openshift/$Namespace-sizing.csv" -ForegroundColor White
    Write-Host ""
    Write-Host "  3. Manual execution for debugging:" -ForegroundColor Gray
    Write-Host "     oc exec deployment/pod-health-monitor -n $Namespace -- bash /scripts/right-sizing.sh" -ForegroundColor White
    Write-Host ""
    exit $exitCode
}

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
