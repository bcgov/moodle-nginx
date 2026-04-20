<#
.SYNOPSIS
    Diagnose MariaDB Galera configuration priority and why settings aren't applying

.DESCRIPTION
    Comprehensive diagnostic to understand:
    1. What configuration sources exist
    2. What mysqld command line is actually running
    3. Why MARIADB_EXTRA_FLAGS may not be applying
    4. Configuration file vs command-line priority

.PARAMETER Namespace
    OpenShift namespace to diagnose

.EXAMPLE
    .\scripts\diagnose-galera-config-priority.ps1 -Namespace 950003-dev
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Namespace
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " GALERA CONFIGURATION PRIORITY DIAGNOSIS" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

$pod = "mariadb-galera-0"

Write-Host "[1] ENVIRONMENT VARIABLES IN POD" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor DarkGray
Write-Host ""

# Check MARIADB_EXTRA_FLAGS from pod environment
Write-Host "  Checking MARIADB_EXTRA_FLAGS..." -ForegroundColor Cyan
$extraFlags = oc exec $pod -n $Namespace -- bash -c 'echo "$MARIADB_EXTRA_FLAGS"' 2>&1
if ($LASTEXITCODE -eq 0) {
    if ([string]::IsNullOrWhiteSpace($extraFlags)) {
        Write-Host "    [WARNING] MARIADB_EXTRA_FLAGS is NOT SET in pod environment" -ForegroundColor Yellow
    } else {
        Write-Host "    [OK] MARIADB_EXTRA_FLAGS exists:" -ForegroundColor Green
        Write-Host "    $extraFlags" -ForegroundColor White
    }
} else {
    Write-Host "    [ERROR] Could not read environment: $extraFlags" -ForegroundColor Red
}

Write-Host ""

# Check all MARIADB_* environment variables
Write-Host "  All MARIADB_* environment variables:" -ForegroundColor Cyan
$allMariadbEnv = oc exec $pod -n $Namespace -- bash -c 'env | grep ^MARIADB_ | sort' 2>&1
if ($LASTEXITCODE -eq 0) {
    $allMariadbEnv -split "`n" | ForEach-Object {
        Write-Host "    $_" -ForegroundColor Gray
    }
} else {
    Write-Host "    [ERROR] Could not read environment" -ForegroundColor Red
}

Write-Host ""
Write-Host ""

Write-Host "[2] MYSQLD PROCESS COMMAND LINE" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Actual mysqld command running in container:" -ForegroundColor Cyan

$mysqldCmd = oc exec $pod -n $Namespace -- bash -c 'ps aux | grep mysqld | grep -v grep' 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "$mysqldCmd" -ForegroundColor White
    Write-Host ""

    # Check if wsrep-provider-options is in command line
    if ($mysqldCmd -match "--wsrep-provider-options") {
        Write-Host "    [OK] --wsrep-provider-options found in command line" -ForegroundColor Green

        # Extract the options
        if ($mysqldCmd -match "--wsrep-provider-options[= ]'([^']+)'") {
            Write-Host "    Options: $($matches[1])" -ForegroundColor White
        } elseif ($mysqldCmd -match '--wsrep-provider-options[= ]"([^"]+)"') {
            Write-Host "    Options: $($matches[1])" -ForegroundColor White
        }
    } else {
        Write-Host "    [CRITICAL] --wsrep-provider-options NOT in command line!" -ForegroundColor Red
        Write-Host "    This means MARIADB_EXTRA_FLAGS is not being applied!" -ForegroundColor Red
    }
} else {
    Write-Host "    [ERROR] Could not get process list: $mysqldCmd" -ForegroundColor Red
}

Write-Host ""
Write-Host ""

Write-Host "[3] CONFIGMAP CONFIGURATION" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor DarkGray
Write-Host ""

$configMapData = oc get configmap mariadb-galera-configuration -n $Namespace -o jsonpath='{.data.my\.cnf}' 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "  ConfigMap my.cnf content (galera section):" -ForegroundColor Cyan
    Write-Host ""

    # Extract [galera] section
    $inGaleraSection = $false
    $configMapData -split "`n" | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "[galera]") {
            $inGaleraSection = $true
            Write-Host "    $line" -ForegroundColor Yellow
        } elseif ($line -match '^\[' -and $inGaleraSection) {
            $inGaleraSection = $false
        } elseif ($inGaleraSection) {
            if ($line -match "wsrep_provider_options") {
                Write-Host "    $line" -ForegroundColor White
            } else {
                Write-Host "    $line" -ForegroundColor Gray
            }
        }
    }

    Write-Host ""

    # Check if wsrep_provider_options exists in ConfigMap
    if ($configMapData -match "wsrep_provider_options") {
        Write-Host "    [FOUND] wsrep_provider_options in ConfigMap" -ForegroundColor Yellow
        $configLine = ($configMapData -split "`n" | Where-Object { $_ -match "wsrep_provider_options" })[0]
        Write-Host "    $configLine" -ForegroundColor White
    } else {
        Write-Host "    [NOT FOUND] wsrep_provider_options not in ConfigMap" -ForegroundColor Gray
    }
} else {
    Write-Host "    [ERROR] Could not read ConfigMap: $configMapData" -ForegroundColor Red
}

Write-Host ""
Write-Host ""

Write-Host "[4] RUNTIME MYSQL CONFIGURATION" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor DarkGray
Write-Host ""

Write-Host "  Querying MySQL for actual wsrep_provider_options..." -ForegroundColor Cyan
$mysqlQuery = oc exec $pod -n $Namespace -- bash -c 'mysql -uroot -p$(cat $MARIADB_ROOT_PASSWORD_FILE) -sN -e "SHOW VARIABLES LIKE \"wsrep_provider_options\";"' 2>&1

if ($LASTEXITCODE -eq 0) {
    Write-Host ""
    Write-Host "$mysqlQuery" -ForegroundColor White
    Write-Host ""

    # Extract inactive_timeout specifically
    if ($mysqlQuery -match "evs\.inactive_timeout\s*=\s*([^;]+)") {
        $runtimeTimeout = $matches[1].Trim()
        Write-Host "    Current evs.inactive_timeout: $runtimeTimeout" -ForegroundColor $(if ($runtimeTimeout -eq "PT15S") { "Red" } else { "Green" })
    }
} else {
    Write-Host "    [ERROR] Could not query MySQL: $mysqlQuery" -ForegroundColor Red
}

Write-Host ""
Write-Host ""

Write-Host "[5] HELM RELEASE CONFIGURATION" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor DarkGray
Write-Host ""

$helmRelease = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.metadata.labels.app\.kubernetes\.io/instance}' 2>&1
if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($helmRelease)) {
    Write-Host "  Helm Release: $helmRelease" -ForegroundColor Cyan
    Write-Host ""

    # Check helm status
    Write-Host "  Checking Helm values..." -ForegroundColor Cyan
    $helmValues = helm get values $helmRelease -n $Namespace 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-Host ""
        Write-Host "$helmValues" -ForegroundColor Gray
        Write-Host ""

        if ($helmValues -match "extraFlags") {
            Write-Host "    [FOUND] extraFlags in Helm values" -ForegroundColor Green
        } else {
            Write-Host "    [NOT FOUND] extraFlags not in Helm values" -ForegroundColor Yellow
            Write-Host "    This may be why MARIADB_EXTRA_FLAGS isn't applying" -ForegroundColor Yellow
        }
    } else {
        Write-Host "    [ERROR] Could not get Helm values: $helmValues" -ForegroundColor Red
    }

    Write-Host ""

    # Get full Helm manifest
    Write-Host "  Checking deployed StatefulSet from Helm..." -ForegroundColor Cyan
    $helmManifest = helm get manifest $helmRelease -n $Namespace 2>&1 | Select-String -Pattern "MARIADB_EXTRA_FLAGS" -Context 0,3

    if ($helmManifest) {
        Write-Host ""
        Write-Host "$helmManifest" -ForegroundColor Gray
    } else {
        Write-Host "    [NOT FOUND] MARIADB_EXTRA_FLAGS not in Helm manifest" -ForegroundColor Yellow
    }

} else {
    Write-Host "  [INFO] Not a Helm-managed deployment" -ForegroundColor Gray
}

Write-Host ""
Write-Host ""

Write-Host "[6] STATEFULSET ENVIRONMENT CONFIGURATION" -ForegroundColor Yellow
Write-Host "================================================" -ForegroundColor DarkGray
Write-Host ""

Write-Host "  Checking StatefulSet spec for MARIADB_EXTRA_FLAGS..." -ForegroundColor Cyan
$stsEnv = oc get statefulset mariadb-galera -n $Namespace -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MARIADB_EXTRA_FLAGS")]}' 2>&1

if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($stsEnv)) {
    Write-Host ""
    Write-Host "$stsEnv" -ForegroundColor White
    Write-Host ""
    Write-Host "    [OK] MARIADB_EXTRA_FLAGS defined in StatefulSet spec" -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "    [WARNING] MARIADB_EXTRA_FLAGS NOT in StatefulSet spec" -ForegroundColor Yellow
    Write-Host "    This is why the environment variable doesn't exist in pods!" -ForegroundColor Yellow
}

Write-Host ""
Write-Host ""

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " DIAGNOSIS SUMMARY" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Configuration Priority (MariaDB):" -ForegroundColor Yellow
Write-Host "  1. Command-line arguments (--wsrep-provider-options) [HIGHEST]" -ForegroundColor Gray
Write-Host "  2. Configuration file my.cnf (wsrep_provider_options=)" -ForegroundColor Gray
Write-Host "  3. Built-in defaults [LOWEST]" -ForegroundColor Gray
Write-Host ""

Write-Host "Bitnami Container Startup Flow:" -ForegroundColor Yellow
Write-Host "  1. Helm values generate ConfigMap" -ForegroundColor Gray
Write-Host "  2. ConfigMap mounted as /opt/bitnami/mariadb/conf/my.cnf" -ForegroundColor Gray
Write-Host "  3. Entrypoint script reads MARIADB_EXTRA_FLAGS environment variable" -ForegroundColor Gray
Write-Host "  4. Entrypoint APPENDS extraFlags to mysqld command line" -ForegroundColor Gray
Write-Host "  5. mysqld starts with: mysqld --defaults-file=/opt/.../my.cnf \$MARIADB_EXTRA_FLAGS" -ForegroundColor Gray
Write-Host ""

Write-Host "How to Fix Configuration:" -ForegroundColor Yellow
Write-Host ""
Write-Host "  Option A - Helm extraFlags (PROPER IaC):" -ForegroundColor Cyan
Write-Host "    helm upgrade $helmRelease bitnami/mariadb-galera -n $Namespace --reuse-values \\" -ForegroundColor White
Write-Host "      --set extraFlags='--wsrep-provider-options=\"evs.inactive_timeout=PT30S\"'" -ForegroundColor White
Write-Host ""
Write-Host "  Option B - Direct StatefulSet Env (Quick fix):" -ForegroundColor Cyan
Write-Host "    oc set env statefulset/mariadb-galera \\" -ForegroundColor White
Write-Host "      MARIADB_EXTRA_FLAGS='--wsrep-provider-options=\"evs.inactive_timeout=PT30S\"' \\" -ForegroundColor White
Write-Host "      -n $Namespace" -ForegroundColor White
Write-Host ""
Write-Host "  Option C - ConfigMap my.cnf (Lowest priority):" -ForegroundColor Cyan
Write-Host "    Edit ConfigMap mariadb-galera-configuration" -ForegroundColor White
Write-Host "    Add: wsrep_provider_options=\"evs.inactive_timeout=PT30S\"" -ForegroundColor White
Write-Host "    (Note: Overridden by command-line if extraFlags set)" -ForegroundColor White
Write-Host ""

Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
