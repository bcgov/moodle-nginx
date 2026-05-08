<#
.SYNOPSIS
    Measure network latency between Galera pods

.DESCRIPTION
    Tests actual network round-trip time between Galera nodes in OpenShift.
    Helps determine if network latency explains split-brain in prod vs dev.

.PARAMETER Namespace
    OpenShift namespace to test

.EXAMPLE
    .\scripts\measure-galera-network-latency.ps1 -Namespace 950003-dev
    .\scripts\measure-galera-network-latency.ps1 -Namespace 950003-prod

.NOTES
    Run this in both dev and prod to compare network characteristics

    Uses root user for MySQL connections (moodle user may not have remote access)
    Uses bash /dev/tcp for port testing (nc not available in Bitnami image)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  GALERA NETWORK LATENCY MEASUREMENT" -ForegroundColor Cyan
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
Write-Host "[OK] Found $($podList.Count) pods: $($podList -join ', ')" -ForegroundColor Green
Write-Host ""

# Test MySQL connection latency between all pod pairs
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  MYSQL CONNECTION LATENCY (Galera Communication Path)" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$latencyResults = @()

# First, verify we can execute commands in the pods
Write-Host "Testing pod connectivity..." -ForegroundColor Gray
$testPod = $podList[0]
$canExec = $false
try {
    $testResult = & oc exec $testPod -n $Namespace -c mariadb-galera -- echo "test" 2>&1
    if ($testResult -match "test") {
        $canExec = $true
        Write-Host "[OK] Can execute commands in pods" -ForegroundColor Green
    }
} catch {
    Write-Host "[ERROR] Cannot execute commands in pods: $_" -ForegroundColor Red
    Write-Host "  Try without -c mariadb-galera flag or check pod status" -ForegroundColor Yellow
    exit 1
}

if (-not $canExec) {
    Write-Host "[ERROR] Pod exec test failed" -ForegroundColor Red
    exit 1
}
Write-Host ""

foreach ($sourcePod in $podList) {
    foreach ($targetPod in $podList) {
        if ($sourcePod -eq $targetPod) { continue }

        $targetService = "$targetPod.mariadb-galera-headless"
        Write-Host "Testing: $sourcePod -> $targetService" -ForegroundColor Gray

        # Measure command execution time using PowerShell
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            # Use MARIADB_ROOT_USER and read password from MARIADB_ROOT_PASSWORD_FILE
            # Strip any whitespace from password file
            $bashCommand = 'PASS=$(cat $MARIADB_ROOT_PASSWORD_FILE | tr -d "\\n\\r"); mysql -h ' + $targetService + ' -u$MARIADB_ROOT_USER --password="$PASS" -e "SELECT 1" 2>&1'

            Write-Verbose "Command: bash -c '$bashCommand'" -Verbose:$VerbosePreference

            # Execute via oc exec
            $mysqlResult = & oc exec $sourcePod -n $Namespace -c mariadb-galera -- bash -c $bashCommand 2>&1

            $stopwatch.Stop()
            $totalSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

            Write-Verbose "Result: $mysqlResult" -Verbose:$VerbosePreference
            Write-Verbose "Exit code: $LASTEXITCODE" -Verbose:$VerbosePreference

            # Check for errors in result
            if ($LASTEXITCODE -ne 0 -or $mysqlResult -match "ERROR") {
                # MySQL remote connection failed, try local query instead
                # This tests if the target pod is reachable via service name from source pod
                Write-Verbose "Direct MySQL failed, trying simplified test..." -Verbose:$VerbosePreference

                # Just verify we can resolve and reach the service
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                $pingTest = & oc exec $sourcePod -n $Namespace -c mariadb-galera -- timeout 5 bash -c "cat < /dev/tcp/$targetService/3306" 2>&1
                $stopwatch.Stop()
                $totalSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

                if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 124) {
                    # Port 3306 (MySQL) is reachable
                    $status = if ($totalSeconds -lt 5) { "GOOD" }
                             elseif ($totalSeconds -lt 10) { "OK" }
                             elseif ($totalSeconds -lt 15) { "WARN" }
                             else { "CRITICAL" }

                    $color = switch ($status) {
                        "GOOD" { "Green" }
                        "OK" { "Cyan" }
                        "WARN" { "Yellow" }
                        "CRITICAL" { "Red" }
                    }

                    Write-Host "  Result: $($totalSeconds)s [$status] (TCP test)" -ForegroundColor $color

                    $latencyResults += @{
                        Source = $sourcePod
                        Target = $targetPod
                        Latency = $totalSeconds
                        Status = $status
                    }
                } else {
                    # Both MySQL and TCP failed
                    $errorMsg = ($mysqlResult | Select-Object -First 2) -join " | "
                    Write-Host "  [ERROR] MySQL auth failed, TCP test also failed" -ForegroundColor Red
                    Write-Verbose "MySQL error: $errorMsg" -Verbose:$VerbosePreference
                    $latencyResults += @{
                        Source = $sourcePod
                        Target = $targetPod
                        Latency = -1
                        Status = "ERROR"
                    }
                }
            } else {
                $status = if ($totalSeconds -lt 5) { "GOOD" }
                         elseif ($totalSeconds -lt 10) { "OK" }
                         elseif ($totalSeconds -lt 15) { "WARN" }
                         else { "CRITICAL" }

                $color = switch ($status) {
                    "GOOD" { "Green" }
                    "OK" { "Cyan" }
                    "WARN" { "Yellow" }
                    "CRITICAL" { "Red" }
                }

                Write-Host "  Result: $($totalSeconds)s [$status]" -ForegroundColor $color

                $latencyResults += @{
                    Source = $sourcePod
                    Target = $targetPod
                    Latency = $totalSeconds
                    Status = $status
                }
            }
        } catch {
            $stopwatch.Stop()
            Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
            $latencyResults += @{
                Source = $sourcePod
                Target = $targetPod
                Latency = -1
                Status = "ERROR"
            }
        }
    }
    Write-Host ""
}

# Test port connectivity (Galera replication port 4567)
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  GALERA REPLICATION PORT (4567) CONNECTIVITY" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

foreach ($sourcePod in $podList) {
    foreach ($targetPod in $podList) {
        if ($sourcePod -eq $targetPod) { continue }

        $targetService = "$targetPod.mariadb-galera-headless"
        Write-Host "Testing: $sourcePod -> $targetService:4567" -ForegroundColor Gray

        # Measure command execution time using PowerShell
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

        try {
            # Test port connectivity using bash's built-in /dev/tcp (nc not available in Bitnami image)
            $testCmd = "timeout 5 bash -c 'cat < /dev/tcp/$targetService/4567' 2>&1"
            $tcpResult = & oc exec $sourcePod -n $Namespace -c mariadb-galera -- bash -c $testCmd 2>&1

            $stopwatch.Stop()
            $totalSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 2)

            # Check if connection succeeded (exit code 0 or 124 for timeout means port is open)
            if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 124) {
                $status = if ($totalSeconds -lt 2) { "EXCELLENT" }
                         elseif ($totalSeconds -lt 5) { "GOOD" }
                         elseif ($totalSeconds -lt 10) { "WARN" }
                         else { "CRITICAL" }

                $color = switch ($status) {
                    "EXCELLENT" { "Green" }
                    "GOOD" { "Cyan" }
                    "WARN" { "Yellow" }
                    "CRITICAL" { "Red" }
                }

                Write-Host "  Result: $($totalSeconds)s [$status]" -ForegroundColor $color
            } else {
                Write-Host "  [ERROR] Port 4567 not accessible" -ForegroundColor Red
            }
        } catch {
            $stopwatch.Stop()
            Write-Host "  [ERROR] $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    Write-Host ""
}

# Summary and recommendations
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  ANALYSIS SUMMARY" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""

$validResults = $latencyResults | Where-Object { $_.Latency -gt 0 }
if ($validResults.Count -eq 0) {
    Write-Host "[ERROR] No valid latency measurements" -ForegroundColor Red
    exit 1
}

$avgLatency = ($validResults | Measure-Object -Property Latency -Average).Average
$maxLatency = ($validResults | Measure-Object -Property Latency -Maximum).Maximum
$minLatency = ($validResults | Measure-Object -Property Latency -Minimum).Minimum

Write-Host "  Average Latency: $([math]::Round($avgLatency, 2))s" -ForegroundColor White
Write-Host "  Maximum Latency: $([math]::Round($maxLatency, 2))s" -ForegroundColor White
Write-Host "  Minimum Latency: $([math]::Round($minLatency, 2))s" -ForegroundColor White
Write-Host ""

# Recommendations based on latency
Write-Host "  Recommended Timeout Profile:" -ForegroundColor Cyan

if ($maxLatency -lt 5) {
    Write-Host "    [RECOMMENDATION] Default (PT15S) - Low latency environment" -ForegroundColor Green
    Write-Host "      Your network is fast enough for tight timeouts" -ForegroundColor Gray
} elseif ($maxLatency -lt 10) {
    Write-Host "    [RECOMMENDATION] Dev (PT20S) - Moderate latency" -ForegroundColor Cyan
    Write-Host "      Network latency approaching timeout threshold" -ForegroundColor Gray
} elseif ($maxLatency -lt 15) {
    Write-Host "    [RECOMMENDATION] Test (PT25S) - High latency" -ForegroundColor Yellow
    Write-Host "      Network latency near PT15S default timeout" -ForegroundColor Gray
    Write-Host "      [WARNING] PT15S may trigger false split-brain" -ForegroundColor Yellow
} else {
    Write-Host "    [RECOMMENDATION] Prod (PT30S) - Critical latency" -ForegroundColor Red
    Write-Host "      Network latency EXCEEDS PT15S default timeout" -ForegroundColor Red
    Write-Host "      [CRITICAL] PT15S WILL cause split-brain" -ForegroundColor Red
}

Write-Host ""
Write-Host "  Deploy timeout configuration:" -ForegroundColor Gray
Write-Host "    .\scripts\deploy-galera-timeouts.ps1 -Namespace $Namespace -Profile <profile>" -ForegroundColor White
Write-Host ""

# Compare with other environments
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host "  NEXT STEPS" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  1. Run this in other environments to compare:" -ForegroundColor Gray
Write-Host "     .\scripts\measure-galera-network-latency.ps1 -Namespace 950003-dev" -ForegroundColor White
Write-Host "     .\scripts\measure-galera-network-latency.ps1 -Namespace 950003-test" -ForegroundColor White
Write-Host "     .\scripts\measure-galera-network-latency.ps1 -Namespace 950003-prod" -ForegroundColor White
Write-Host ""
Write-Host "  2. Compare results:" -ForegroundColor Gray
Write-Host "     - If prod has 2-3x higher latency than dev: Network is the issue" -ForegroundColor White
Write-Host "     - If latency is similar: Resource contention is the issue" -ForegroundColor White
Write-Host ""
Write-Host "  3. Check resource usage:" -ForegroundColor Gray
Write-Host "     oc adm top pods -n $Namespace -l app.kubernetes.io/name=mariadb-galera" -ForegroundColor White
Write-Host ""
