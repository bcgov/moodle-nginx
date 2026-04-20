param([string]$Namespace = "950003-prod", [int]$IntervalSeconds = 30, [switch]$Once, [switch]$AutoHeal)
$ErrorActionPreference = "Stop"
Write-Host "Galera Split-Brain Monitor | Namespace: $Namespace" -ForegroundColor Cyan

# Verify pod-health-monitor has the required scripts
Write-Host "Verifying pod-health-monitor deployment..." -ForegroundColor Gray
$filesCheck = oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "ls -la /scripts/ /scripts/utils/ 2>&1" 2>&1
if ($filesCheck -match "No such file") {
    Write-Host "ERROR: pod-health-monitor deployment is missing required scripts!" -ForegroundColor Red
    Write-Host "The /scripts/utils/database.sh file is not present in the container." -ForegroundColor Red
    Write-Host ""
    Write-Host "To fix this, redeploy pod-health-monitor:" -ForegroundColor Yellow
    Write-Host "  oc apply -f .\openshift\pod-health-monitor.yml" -ForegroundColor Cyan
    Write-Host "  oc rollout restart deployment/pod-health-monitor -n $Namespace" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Files found in container:" -ForegroundColor Gray
    $filesCheck | Write-Host
    exit 1
}

function Check-Cluster {
    $ts = Get-Date -Format "HH:mm:ss"
    Write-Host "`n[$ts] Checking cluster health..." -ForegroundColor Yellow
    $out = oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "source /scripts/utils/database.sh; check_galera_cluster_health 'app.kubernetes.io/name=mariadb-galera' '$Namespace'; echo EXIT:`$?" 2>&1
    $out | ? { $_ -notmatch "Default" } | % { if ($_ -match "EXIT:(\d+)") { $global:ec = $Matches[1] } else { Write-Host $_ } }
    if ($global:ec -eq 0) { Write-Host "✅ HEALTHY" -ForegroundColor Green; return $true }
    if ($global:ec -eq 2) { Write-Host "🚨 SPLIT-BRAIN!" -ForegroundColor Red; if($AutoHeal){oc exec deployment/pod-health-monitor -n $Namespace -- bash -c "source /scripts/utils/database.sh;auto_heal_galera_cluster 'app.kubernetes.io/name=mariadb-galera' '$Namespace'" 2>&1}; return $false }
    Write-Host "⚠️ UNHEALTHY" -ForegroundColor Red; return $false
}
if ($Once) { exit $(if (Check-Cluster) { 0 } else { 1 }) }
while ($true) { Check-Cluster; Write-Host "`nNext in ${IntervalSeconds}s...`n" -ForegroundColor Gray; sleep $IntervalSeconds }

