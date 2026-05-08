<#
.SYNOPSIS
    Upload bash scripts and configs from ./openshift to pod-health-monitor via ConfigMaps

.DESCRIPTION
    Creates/updates two ConfigMaps for pod-health-monitor:

    1. openshift-scripts > /scripts/
       - All bash scripts from openshift/scripts/ (recursive)
       - Preserves existing /scripts/_utils.sh path
       - No changes needed to universal loader pattern

    2. openshift-resources > /openshift/
       - CSVs: 950003-*-sizing.csv
       - YAMLs: *.yml deployment templates
       - Dependencies: dependencies/*
       - Excludes PowerShell scripts (not needed in-cluster)

    This maintains backward compatibility while auto-including new files.

.PARAMETER Namespace
    Target OpenShift namespace (required). Format: ######-(dev|test|prod)

.PARAMETER SkipRestart
    Update ConfigMaps only, don't restart pod-health-monitor deployment

.EXAMPLE
    # Upload scripts + resources and restart pod-health-monitor
    .\scripts\update-pod-health-scripts.ps1 -Namespace 950003-dev

.EXAMPLE
    # Upload without restarting (manual restart later)
    .\scripts\update-pod-health-scripts.ps1 -Namespace 950003-prod -SkipRestart

.NOTES
    ConfigMap limits: 1 MB each
    Current sizes: scripts ~0.7 MB, resources ~0.06 MB

    Pod mount points:
      /scripts/_utils.sh (universal loader with intelligent path detection)
      /scripts/*.sh (all operational scripts)
      /scripts/utils-*.sh (utility scripts, flattened from utils/ subdirectory)
      /openshift/*.csv (sizing configs)
      /openshift/*.yml (deployment templates)

    PATH STRATEGY:
      ConfigMap keys are flattened (utils/database.sh → utils-database.sh)
      because Kubernetes doesn't allow '/' in keys. Scripts use intelligent
      path resolution to support both flattened paths (current) and natural
      subdirectories (future items[] approach).

      Script detection order:
        1. Natural:   /scripts/utils/database.sh (if volumeMount uses items[].path)
        2. Flattened: /scripts/utils-database.sh (current automatic approach)
        3. Flat:      /scripts/database.sh       (legacy)

      See: docs/galera-deployment-best-practices.md#configmap-path-strategy

    FUTURE ENHANCEMENT (OPTIONAL):
      To enable natural paths matching repo structure:
        1. Uncomment "Generate items[] mapping" section below
        2. Copy output to pod-health-monitor.yml volumes.openshift-scripts.items
        3. Verify with: ls -la /scripts/utils/ (should show subdirectory)

      Scripts will automatically detect and use natural paths when available.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Target OpenShift namespace (e.g., 950003-dev)")]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(Mandatory = $false, HelpMessage = "Skip restarting pod-health-monitor deployment")]
    [switch]$SkipRestart
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  OPENSHIFT > POD-HEALTH-MONITOR" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Namespace: $Namespace" -ForegroundColor Gray
Write-Host "  ConfigMaps: openshift-scripts, openshift-resources" -ForegroundColor Gray
Write-Host ""

# Configuration
$DeploymentName = "pod-health-monitor"
$ScriptDir = Split-Path -Parent $PSScriptRoot
$OpenshiftPath = Join-Path $ScriptDir "openshift"
$ScriptsPath = Join-Path $OpenshiftPath "scripts"

# Validate source directories exist
if (-not (Test-Path $OpenshiftPath)) {
    Write-Host "[ERROR] openshift/ directory not found: $OpenshiftPath" -ForegroundColor Red
    exit 1
}
if (-not (Test-Path $ScriptsPath)) {
    Write-Host "[ERROR] openshift/scripts/ directory not found: $ScriptsPath" -ForegroundColor Red
    exit 1
}

# Helper function to normalize line endings (CRLF -> LF) for Linux compatibility
function ConvertTo-UnixLineEndings {
    param([string]$FilePath)

    # Read as UTF8 to preserve emoji and special characters
    $content = Get-Content -Path $FilePath -Raw -Encoding UTF8
    # Convert CRLF to LF
    $content = $content -replace "`r`n", "`n"
    # Convert any remaining CR to LF
    $content = $content -replace "`r", "`n"

    # Write to temp file with UTF8 (no BOM) and LF line endings
    $tempFile = [System.IO.Path]::GetTempFileName()
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($tempFile, $content, $utf8NoBom)

    return $tempFile
}

# =============================================================================
# CONFIGMAP 1: openshift-scripts > /scripts/
# =============================================================================
Write-Host "[1/2] Preparing openshift-scripts ConfigMap..." -ForegroundColor Cyan

# Collect all bash scripts from openshift/scripts/ (recursively)
# Exclude: .git folders, -legacy.sh files (archived originals), CI/CD-only scripts
# CI/CD scripts are only used by GitHub Actions deploy workflows, not by the monitor pod.
# This keeps the ConfigMap under the 1MB Kubernetes limit.
$cicdOnlyPatterns = @(
    "deploy-*", "build-*", "migrate-*", "optimize-*",
    "validate-*", "test-*", "comprehensive-*", "ensure-*",
    "right-sizing*", "helm-image-*", "populate-*",
    "lighthouse-*", "fix-mojibake-*", "moodle-mojibake-*",
    "openshift-list-*", "moodle-upgrade*", "enable-maintenance*",
    "deploy-memcached*"
)
$bashScripts = Get-ChildItem -Path $ScriptsPath -Recurse -File -Include "*.sh" |
    Where-Object {
        $name = $_.Name
        $_.FullName -notlike "*\.git*" -and
        $name -notlike "*-legacy.sh" -and
        -not ($cicdOnlyPatterns | Where-Object { $name -like $_ })
    }

Write-Host "  Found $($bashScripts.Count) bash scripts (excluding legacy + CI/CD-only files)" -ForegroundColor Gray

# Build --from-file arguments with flattened keys (ConfigMap keys cannot contain /)
$scriptsArgs = @()
$tempFiles = @()
foreach ($script in $bashScripts) {
    # Get path relative to scripts directory
    $relativePath = $script.FullName.Substring($ScriptsPath.Length + 1)

    # Convert to Unix line endings
    $tempFile = ConvertTo-UnixLineEndings -FilePath $script.FullName
    $tempFiles += $tempFile

    # Flatten key name: replace \ and / with - (e.g., utils/database.sh > utils-database.sh)
    $keyName = $relativePath.Replace('\', '-').Replace('/', '-')

    # Add to arguments
    $scriptsArgs += "--from-file=$keyName=$tempFile"
}

Write-Host "  Creating/updating openshift-scripts ConfigMap..." -ForegroundColor Gray

# Delete existing ConfigMap if present (--ignore-not-found prevents errors)
oc delete configmap openshift-scripts -n $Namespace --ignore-not-found=true 2>&1 | Out-Null

# Create ConfigMap
$createScriptsCmd = "oc create configmap openshift-scripts -n $Namespace $($scriptsArgs -join ' ')"
Invoke-Expression $createScriptsCmd | Out-Null

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Failed to create openshift-scripts ConfigMap" -ForegroundColor Red
    exit 1
}

Write-Host "  [OK] openshift-scripts ConfigMap created ($($bashScripts.Count) files)" -ForegroundColor Green

# Cleanup temp files
foreach ($tempFile in $tempFiles) {
    if (Test-Path $tempFile) {
        Remove-Item $tempFile -Force
    }
}

# =============================================================================
# CONFIGMAP 2: openshift-resources > /openshift/
# =============================================================================
Write-Host ""
Write-Host "[2/2] Preparing openshift-resources ConfigMap..." -ForegroundColor Cyan

# Collect resources from openshift/ root (exclude scripts/ subdirectory and .ps1 files)
$resources = Get-ChildItem -Path $OpenshiftPath -File -Recurse |
    Where-Object {
        $_.FullName -notlike "*\scripts\*" -and
        $_.Extension -ne ".ps1" -and
        $_.FullName -notlike "*\.git*"
    }

Write-Host "  Found $($resources.Count) resource files (CSVs, YAMLs, dependencies)" -ForegroundColor Gray

# Build --from-file arguments with flattened keys
$resourcesArgs = @()
$tempResourceFiles = @()
foreach ($resource in $resources) {
    # Get path relative to openshift directory
    $relativePath = $resource.FullName.Substring($OpenshiftPath.Length + 1)

    # Flatten key name: replace \ and / with - (e.g., dependencies/Chart.yaml > dependencies-Chart.yaml)
    $keyName = $relativePath.Replace('\', '-').Replace('/', '-')

    # Convert line endings for text files that will be parsed by bash
    $filePath = $resource.FullName
    if ($resource.Extension -in @('.csv', '.txt', '.conf', '.cfg')) {
        $tempFile = ConvertTo-UnixLineEndings -FilePath $resource.FullName
        $tempResourceFiles += $tempFile
        $filePath = $tempFile
    }

    # Add to arguments
    $resourcesArgs += "--from-file=$keyName=$filePath"
}

Write-Host "  Creating/updating openshift-resources ConfigMap..." -ForegroundColor Gray

# Delete existing ConfigMap if present (--ignore-not-found prevents errors)
oc delete configmap openshift-resources -n $Namespace --ignore-not-found=true 2>&1 | Out-Null

# Create ConfigMap
if ($resourcesArgs.Count -gt 0) {
    $createResourcesCmd = "oc create configmap openshift-resources -n $Namespace $($resourcesArgs -join ' ')"
    Invoke-Expression $createResourcesCmd | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to create openshift-resources ConfigMap" -ForegroundColor Red
        exit 1
    }

    Write-Host "  [OK] openshift-resources ConfigMap created ($($resources.Count) files)" -ForegroundColor Green
} else {
    Write-Host "  [WARN] No resources found (skipping)" -ForegroundColor Yellow
}

# Cleanup temp resource files
foreach ($tempFile in $tempResourceFiles) {
    if (Test-Path $tempFile) {
        Remove-Item $tempFile -Force
    }
}

# =============================================================================
# RESTART DEPLOYMENT
# =============================================================================
if (-not $SkipRestart) {
    Write-Host ""
    Write-Host "Restarting $DeploymentName deployment..." -ForegroundColor Cyan

    # Check if deployment exists
    $deployment = oc get deployment $DeploymentName -n $Namespace 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  [WARN] Deployment $DeploymentName not found - ConfigMaps updated but no restart" -ForegroundColor Yellow
    } else {
        oc rollout restart deployment/$DeploymentName -n $Namespace | Out-Null
        Write-Host "  [OK] Deployment restarted" -ForegroundColor Green

        Write-Host "  Waiting for rollout to complete..." -ForegroundColor Gray
        oc rollout status deployment/$DeploymentName -n $Namespace --timeout=120s

        if ($LASTEXITCODE -eq 0) {
            Write-Host "  [OK] Rollout complete" -ForegroundColor Green
        } else {
            Write-Host "  [WARN] Rollout timeout - check deployment status manually" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host ""
    Write-Host "[SKIP] Skipped deployment restart (use -SkipRestart:`$false to restart)" -ForegroundColor Yellow
}

# =============================================================================
# OPTIONAL: Generate items[] Mapping for Natural Paths
# =============================================================================
# Uncomment this section to generate volumeMount.items[] YAML for pod-health-monitor.yml
# This enables natural subdirectory paths (/scripts/utils/database.sh) instead of flattened
# paths (/scripts/utils-database.sh).
#
# See: docs/galera-deployment-best-practices.md#configmap-path-strategy
# =============================================================================
<#
Write-Host ""
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  OPTIONAL: items[] Mapping for Natural Paths" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Copy the following to pod-health-monitor.yml under:" -ForegroundColor Yellow
Write-Host "  volumes.openshift-scripts.configMap.items" -ForegroundColor Yellow
Write-Host ""

# Generate items[] YAML snippet
Write-Host "      items:" -ForegroundColor Green
foreach ($script in $bashScripts) {
    $relativePath = $script.FullName.Substring($ScriptsPath.Length + 1)
    $keyName = $relativePath.Replace('\', '-').Replace('/', '-')
    $pathName = $relativePath.Replace('\', '/')

    Write-Host "      - key: $keyName" -ForegroundColor Green
    Write-Host "        path: $pathName" -ForegroundColor Green
}

Write-Host ""
Write-Host "After adding items[] to pod-health-monitor.yml:" -ForegroundColor Yellow
Write-Host "  1. Apply the updated YAML: oc apply -f openshift/pod-health-monitor.yml" -ForegroundColor Gray
Write-Host "  2. Restart deployment: oc rollout restart deployment/pod-health-monitor -n $Namespace" -ForegroundColor Gray
Write-Host "  3. Verify natural paths: oc exec deployment/pod-health-monitor -n $Namespace -- ls -la /scripts/utils/" -ForegroundColor Gray
Write-Host ""
Write-Host "Scripts will automatically detect and use natural paths!" -ForegroundColor Green
#>

Write-Host ""
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  [SUCCESS] COMPLETE" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
Write-Host "ConfigMaps created:" -ForegroundColor Gray
Write-Host "  - openshift-scripts > /scripts/ ($($bashScripts.Count) bash scripts)" -ForegroundColor Gray
Write-Host "  - openshift-resources > /openshift/ ($($resources.Count) config files)" -ForegroundColor Gray
Write-Host ""
Write-Host "Verify mount in pod:" -ForegroundColor Gray
Write-Host "  oc exec deployment/$DeploymentName -n $Namespace -- ls -la /scripts/" -ForegroundColor DarkGray
Write-Host "  oc exec deployment/$DeploymentName -n $Namespace -- ls -la /openshift/" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Example: Access scripts in pod" -ForegroundColor Gray
Write-Host "  oc exec -it deployment/pod-health-monitor -n $Namespace -- bash /scripts/galera-inspect.sh" -ForegroundColor White
Write-Host "  oc exec -it deployment/pod-health-monitor -n $Namespace -- bash /scripts/right-sizing.sh" -ForegroundColor White
Write-Host ""
Write-Host "Note: Subdirectory scripts are flattened (utils/database.sh > utils-database.sh)" -ForegroundColor DarkGray
