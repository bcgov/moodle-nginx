<#
.SYNOPSIS
    Check all sources of Galera timeout configuration

.DESCRIPTION
    Examines all possible sources where Galera timeouts might be configured:
    - MARIADB_EXTRA_FLAGS environment variable
    - ConfigMap mariadb-galera-configuration (my.cnf)
    - Actual running configuration in MySQL

    Identifies conflicts and recommends cleanup.

.PARAMETER Namespace
    OpenShift namespace to check

.EXAMPLE
    .\scripts\check-galera-timeout-config.ps1 -Namespace 950003-dev

.NOTES
    MARIADB_EXTRA_FLAGS and ConfigMap wsrep_provider_options CONFLICT
    Only one source should be used to avoid confusion
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  GALERA TIMEOUT CONFIGURATION AUDIT" -ForegroundColor Cyan
Write-Host "  Namespace: $Namespace" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

# Get pod list
Write-Host "[INFO] Getting pod list..." -ForegroundColor Cyan
$pods = oc get pods -l app.kubernetes.io/name=mariadb-galera -n $Namespace -o jsonpath='{.items[*].metadata.name}' 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[ERROR] Failed to get pods: $pods" -ForegroundColor Red
    exit 1
}

$podList = ($pods -split '\s+') | Where-Object { $_ -ne '' }
if ($podList.Count -eq 0) {
    Write-Host "[ERROR] No MariaDB Galera pods found" -ForegroundColor Red
    exit 1
}

$pod = $podList[0]
Write-Host "[OK] Using pod: $pod" -ForegroundColor Green
Write-Host ""

# Check 0: Helm values (if deployed via Helm)
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  SOURCE 0: Helm Values (Infrastructure-as-Code)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$helmRelease = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($helmRelease)) {
    Write-Host "[INFO] Detected Helm release: $helmRelease" -ForegroundColor Cyan

    # Try to get Helm values
    $helmValues = helm get values $helmRelease -n $Namespace 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[FOUND] Helm values retrieved" -ForegroundColor Green
        Write-Host ""

        # Check for extraFlags in values
        if ($helmValues -match "extraFlags") {
            Write-Host "[CRITICAL] Helm values contain 'extraFlags':" -ForegroundColor Yellow
            $flagLines = $helmValues -split "`n" | Select-String -Pattern "extraFlags" -Context 0,5
            $flagLines | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
            Write-Host ""
            $hasHelmFlags = $true
        } else {
            Write-Host "[OK] No 'extraFlags' found in Helm values" -ForegroundColor Green
            $hasHelmFlags = $false
        }

        # Check for extraEnvVars
        if ($helmValues -match "MARIADB_EXTRA_FLAGS") {
            Write-Host "[CRITICAL] Helm values contain 'MARIADB_EXTRA_FLAGS':" -ForegroundColor Yellow
            $envLines = $helmValues -split "`n" | Select-String -Pattern "MARIADB_EXTRA_FLAGS" -Context 2,2
            $envLines | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
            Write-Host ""
            $hasHelmEnv = $true
        } else {
            Write-Host "[OK] No 'MARIADB_EXTRA_FLAGS' found in Helm values" -ForegroundColor Green
            $hasHelmEnv = $false
        }

        # Also check the full output
        Write-Host "[INFO] Full Helm values:" -ForegroundColor Cyan
        Write-Host $helmValues -ForegroundColor Gray

    } else {
        Write-Host "[WARNING] Could not retrieve Helm values: $helmValues" -ForegroundColor Yellow
        Write-Host "  This might not be a Helm deployment, or Helm is not available" -ForegroundColor Gray
        $hasHelmFlags = $false
        $hasHelmEnv = $false
    }
} else {
    Write-Host "[INFO] StatefulSet does not appear to be managed by Helm" -ForegroundColor Cyan
    Write-Host "  Label 'app.kubernetes.io/instance' not found" -ForegroundColor Gray
    $hasHelmFlags = $false
    $hasHelmEnv = $false
}

Write-Host ""

# Check 1: MARIADB_EXTRA_FLAGS environment variable
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  SOURCE 1: MARIADB_EXTRA_FLAGS Environment Variable" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$extraFlags = oc exec $pod -n $Namespace -c mariadb-galera -- printenv MARIADB_EXTRA_FLAGS 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($extraFlags)) {
    Write-Host "[FOUND] MARIADB_EXTRA_FLAGS is set:" -ForegroundColor Yellow
    Write-Host "  $extraFlags" -ForegroundColor White
    Write-Host ""

    if ($extraFlags -match "wsrep-provider-options") {
        Write-Host "[CONFLICT] Contains wsrep-provider-options!" -ForegroundColor Red
        Write-Host "  This OVERRIDES ConfigMap settings" -ForegroundColor Red
        $hasExtraFlags = $true

        # Extract timeout values
        if ($extraFlags -match "evs\.inactive_timeout=([^;']+)") {
            Write-Host "    evs.inactive_timeout: $($matches[1])" -ForegroundColor Gray
        }
        if ($extraFlags -match "evs\.suspect_timeout=([^;']+)") {
            Write-Host "    evs.suspect_timeout: $($matches[1])" -ForegroundColor Gray
        }
    } else {
        Write-Host "[OK] No timeout configuration in MARIADB_EXTRA_FLAGS" -ForegroundColor Green
        $hasExtraFlags = $false
    }
} else {
    Write-Host "[NOT SET] MARIADB_EXTRA_FLAGS is not configured" -ForegroundColor Green
    $hasExtraFlags = $false
}

Write-Host ""

# Check 2: ConfigMap
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  SOURCE 2: ConfigMap mariadb-galera-configuration" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$configMap = oc get configmap mariadb-galera-configuration -n $Namespace -o yaml 2>&1
if ($LASTEXITCODE -eq 0) {
    if ($configMap -match "wsrep_provider_options") {
        # Extract the wsrep_provider_options line
        $configLines = $configMap -split "`n"
        $wsrepLine = $configLines | Where-Object { $_ -match 'wsrep_provider_options' }

        Write-Host "[FOUND] ConfigMap contains wsrep_provider_options:" -ForegroundColor Yellow
        Write-Host "  $($wsrepLine.Trim())" -ForegroundColor White
        Write-Host ""
        $hasConfigMap = $true

        # Extract timeout values
        if ($wsrepLine -match 'evs\.inactive_timeout=([^;"]+)') {
            Write-Host "    evs.inactive_timeout: $($matches[1])" -ForegroundColor Gray
        }
        if ($wsrepLine -match 'evs\.suspect_timeout=([^;"]+)') {
            Write-Host "    evs.suspect_timeout: $($matches[1])" -ForegroundColor Gray
        }
    } else {
        Write-Host "[NOT SET] ConfigMap does NOT contain wsrep_provider_options" -ForegroundColor Green
        $hasConfigMap = $false
    }
} else {
    Write-Host "[ERROR] Could not read ConfigMap" -ForegroundColor Red
    $hasConfigMap = $false
}

Write-Host ""

# Check 3: Actual running configuration
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  SOURCE 3: Actual Running Configuration (MySQL)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$actualConfig = & oc exec $pod -n $Namespace -c mariadb-galera -- bash -c 'PASS=$(cat $MARIADB_ROOT_PASSWORD_FILE | tr -d "\n\r"); mysql -u$MARIADB_ROOT_USER --password="$PASS" -sN -e "SHOW VARIABLES LIKE '\''wsrep_provider_options'\'';" 2>&1' 2>&1

if ($LASTEXITCODE -eq 0 -and $actualConfig -match "wsrep_provider_options") {
    $actualValue = $actualConfig -replace 'wsrep_provider_options\s+', ''
    Write-Host "[RUNNING] Active wsrep_provider_options:" -ForegroundColor Cyan
    Write-Host "  $actualValue" -ForegroundColor White
    Write-Host ""

    # Extract key timeout values
    if ($actualValue -match "evs\.inactive_timeout\s*=\s*([^;]+)") {
        $actualInactive = $matches[1].Trim()
        Write-Host "  evs.inactive_timeout: $actualInactive" -ForegroundColor $(if ($actualInactive -eq "PT15S") { "Red" } elseif ($actualInactive -match "PT(20|25|30)S") { "Green" } else { "Yellow" })
    }
    if ($actualValue -match "evs\.suspect_timeout\s*=\s*([^;]+)") {
        $actualSuspect = $matches[1].Trim()
        Write-Host "  evs.suspect_timeout: $actualSuspect" -ForegroundColor Gray
    }
} else {
    Write-Host "[ERROR] Could not query running configuration" -ForegroundColor Red
    Write-Host "  Error: $actualConfig" -ForegroundColor Gray
}

Write-Host ""

# Summary and recommendations
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  ANALYSIS & RECOMMENDATIONS" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

if ($hasHelmFlags -or $hasHelmEnv) {
    Write-Host "[HELM-MANAGED] Timeout configuration is in Helm values!" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  This is the CORRECT approach for Infrastructure-as-Code" -ForegroundColor Green
    Write-Host "  Configuration should be managed through Helm, not manual edits" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Current approach (WRONG):" -ForegroundColor Red
    Write-Host "    - deploy-galera-timeouts.ps1 edits ConfigMap manually" -ForegroundColor Red
    Write-Host "    - Helm deployment will overwrite manual changes" -ForegroundColor Red
    Write-Host "    - Not infrastructure-as-code compliant" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Recommended approach (CORRECT):" -ForegroundColor Green
    Write-Host "    - Update Helm values to set desired timeouts" -ForegroundColor Green
    Write-Host "    - Helm upgrade applies consistent configuration" -ForegroundColor Green
    Write-Host "    - Changes are version-controlled and repeatable" -ForegroundColor Green
    Write-Host ""
    Write-Host "  ACTION REQUIRED:" -ForegroundColor Yellow
    Write-Host "    1. Update your Helm values file with desired timeout profile" -ForegroundColor White
    Write-Host "    2. Run Helm upgrade to apply changes" -ForegroundColor White
    Write-Host ""
    Write-Host "  Example Helm values for PT30S profile:" -ForegroundColor Cyan
    Write-Host @"
    extraFlags: >-
      --wsrep-provider-options='evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;gcs.fc_limit=256'
"@ -ForegroundColor White
    Write-Host ""
    Write-Host "  Or using extraEnvVars:" -ForegroundColor Cyan
    Write-Host @"
    extraEnvVars:
      - name: MARIADB_EXTRA_FLAGS
        value: "--wsrep-provider-options='evs.inactive_timeout=PT30S;evs.suspect_timeout=PT10S;gcs.fc_limit=256'"
"@ -ForegroundColor White
    Write-Host ""
    Write-Host "  Then deploy:" -ForegroundColor Cyan
    Write-Host "    helm upgrade mariadb-galera bitnami/mariadb-galera -n $Namespace -f your-values.yaml" -ForegroundColor White
    Write-Host ""

} elseif ($hasExtraFlags -and $hasConfigMap) {
    Write-Host "[CRITICAL CONFLICT] Both MARIADB_EXTRA_FLAGS and ConfigMap are configured!" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Problem:" -ForegroundColor Yellow
    Write-Host "    - MARIADB_EXTRA_FLAGS: Set in StatefulSet/Deployment environment" -ForegroundColor Yellow
    Write-Host "    - ConfigMap wsrep_provider_options: Set in mariadb-galera-configuration" -ForegroundColor Yellow
    Write-Host "    - MARIADB_EXTRA_FLAGS takes precedence (command-line flags override config file)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Recommendation:" -ForegroundColor Cyan
    Write-Host "    1. Remove MARIADB_EXTRA_FLAGS from StatefulSet:" -ForegroundColor White
    Write-Host "       oc set env statefulset/mariadb-galera MARIADB_EXTRA_FLAGS- -n $Namespace" -ForegroundColor White
    Write-Host ""
    Write-Host "    2. Keep timeout configuration in ConfigMap only (our standard approach)" -ForegroundColor White
    Write-Host ""
    Write-Host "    3. Restart pods to apply:" -ForegroundColor White
    Write-Host "       .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace -Profile <profile>" -ForegroundColor White
    Write-Host ""

} elseif ($hasExtraFlags -and -not $hasConfigMap) {
    Write-Host "[WARNING] Using MARIADB_EXTRA_FLAGS (non-standard approach)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Current method: Environment variable MARIADB_EXTRA_FLAGS" -ForegroundColor Yellow
    Write-Host "  Recommended method: ConfigMap mariadb-galera-configuration" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  To switch to ConfigMap approach:" -ForegroundColor Cyan
    Write-Host "    1. Deploy via ConfigMap:" -ForegroundColor White
    Write-Host "       .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace -Profile <profile>" -ForegroundColor White
    Write-Host ""
    Write-Host "    2. Remove MARIADB_EXTRA_FLAGS:" -ForegroundColor White
    Write-Host "       oc set env statefulset/mariadb-galera MARIADB_EXTRA_FLAGS- -n $Namespace" -ForegroundColor White
    Write-Host ""
    Write-Host "    3. Restart pods" -ForegroundColor White
    Write-Host ""

} elseif (-not $hasExtraFlags -and $hasConfigMap) {
    Write-Host "[OK] Using ConfigMap approach (recommended)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Configuration source: mariadb-galera-configuration ConfigMap" -ForegroundColor Green
    Write-Host "  This is the recommended approach for managing Galera timeouts" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  To update timeouts:" -ForegroundColor Cyan
    Write-Host "    .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace -Profile <profile>" -ForegroundColor White
    Write-Host ""

} else {
    Write-Host "[WARNING] No timeout configuration found in either source" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Using MariaDB defaults (PT15S - may be too aggressive for OpenShift)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  To configure timeouts:" -ForegroundColor Cyan
    Write-Host "    .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace -Profile <profile>" -ForegroundColor White
    Write-Host ""
}

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  NEXT STEPS" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

if ($hasExtraFlags) {
    Write-Host "  Run this script to remove MARIADB_EXTRA_FLAGS conflict:" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    # Remove the environment variable" -ForegroundColor Gray
    Write-Host "    oc set env statefulset/mariadb-galera MARIADB_EXTRA_FLAGS- -n $Namespace" -ForegroundColor White
    Write-Host ""
    Write-Host "    # Verify it's gone" -ForegroundColor Gray
    Write-Host "    oc set env statefulset/mariadb-galera --list -n $Namespace | grep EXTRA" -ForegroundColor White
    Write-Host ""
    Write-Host "    # Deploy clean timeout configuration via ConfigMap" -ForegroundColor Gray
    Write-Host "    .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace -Profile Prod" -ForegroundColor White
    Write-Host ""
} else {
    Write-Host "  Configuration looks good. To update timeouts:" -ForegroundColor Cyan
    Write-Host "    .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace -Profile <profile>" -ForegroundColor White
    Write-Host ""
}
