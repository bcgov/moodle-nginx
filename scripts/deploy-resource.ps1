<#
.SYNOPSIS
    Deploy OpenShift resources from YAML templates with auto-detection and parameter substitution

.DESCRIPTION
    Universal deployment script that:
    - Auto-detects resource type (Deployment, StatefulSet, CronJob, Route, etc.)
    - Parses template parameters and prompts for required values
    - Processes templates with parameter substitution
    - Applies resources to the cluster
    - Waits for resource-specific readiness
    - Streams output to console with cluster logs preserved

.PARAMETER Resource
    Path to YAML resource file (required). Relative to repository root.
    Examples: openshift/pod-health-monitor.yml, openshift/web-route.yml

.PARAMETER Namespace
    Target OpenShift namespace (required). Format: ######-(dev|test|prod)

.PARAMETER Parameters
    Hashtable of template parameters to override. Optional.
    Example: @{ MONITOR_IMAGE = "custom-image:tag"; MONITORING_INTERVAL = "120" }

.PARAMETER DryRun
    Show processed YAML without applying to cluster

.EXAMPLE
    # Deploy pod-health-monitor with auto-detected parameters
    .\scripts\deploy-resource.ps1 -Resource openshift/pod-health-monitor.yml -Namespace 950003-dev

.EXAMPLE
    # Deploy with custom parameters
    .\scripts\deploy-resource.ps1 `
        -Resource openshift/pod-health-monitor.yml `
        -Namespace 950003-dev `
        -Parameters @{ MONITORING_INTERVAL = "300" }

.EXAMPLE
    # Dry-run to preview processed YAML
    .\scripts\deploy-resource.ps1 -Resource openshift/web-route.yml -Namespace 950003-dev -DryRun

.NOTES
    Supported resource types:
    - Deployment (with rollout status wait)
    - StatefulSet (with rollout status wait)
    - CronJob (immediate apply)
    - Route (immediate apply)
    - Service, ConfigMap, Secret (immediate apply)
    - Template (processes all objects)

    Auto-detects required parameters from YAML and uses smart defaults:
    - DEPLOY_NAMESPACE > from -Namespace parameter
    - OPENSHIFT_SERVER > from current oc context
    - OPENSHIFT_SA_TOKEN_NAME > auto-detected from namespace
    - MONITOR_IMAGE > from environment or example.secrets
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to YAML resource file")]
    [ValidateScript({ Test-Path $_ })]
    [string]$Resource,

    [Parameter(Mandatory = $true, HelpMessage = "Target OpenShift namespace (e.g., 950003-dev)")]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(Mandatory = $false, HelpMessage = "Template parameters (hashtable)")]
    [hashtable]$Parameters = @{},

    [Parameter(Mandatory = $false, HelpMessage = "Show processed YAML without applying")]
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  DEPLOY OPENSHIFT RESOURCE" -ForegroundColor Cyan
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""

# Resolve absolute path
$ResourcePath = Resolve-Path $Resource
$ResourceName = Split-Path $ResourcePath -Leaf

Write-Host "  Resource: $ResourceName" -ForegroundColor Gray
Write-Host "  Namespace: $Namespace" -ForegroundColor Gray
Write-Host ""

# Parse YAML for resource kind
$yamlContent = Get-Content $ResourcePath -Raw
$kindMatch = $yamlContent | Select-String -Pattern "(?m)^kind:\s*(.+)$"
if (-not $kindMatch) {
    Write-Host "ERROR: Could not detect resource 'kind:' in YAML" -ForegroundColor Red
    exit 1
}
$kind = $kindMatch.Matches[0].Groups[1].Value.Trim()
Write-Host "[INFO] Detected resource type: $kind" -ForegroundColor Cyan

# Parse template parameters (if Template type)
$templateParams = @{}
$isTemplate = $kind -eq "Template"

if ($isTemplate) {
    Write-Host "[INFO] Processing OpenShift Template..." -ForegroundColor Cyan

    # Extract parameter definitions from YAML
    $paramMatches = [regex]::Matches($yamlContent, "(?ms)^  - name:\s*(\S+).*?(?=^  - name:|^objects:|\z)")

    foreach ($match in $paramMatches) {
        $block = $match.Value
        $nameMatch = [regex]::Match($block, "name:\s*(\S+)")
        $requiredMatch = [regex]::Match($block, "required:\s*(true|false)")
        $descMatch = [regex]::Match($block, "description:\s*(.+?)$", [System.Text.RegularExpressions.RegexOptions]::Multiline)

        if ($nameMatch.Success) {
            $paramName = $nameMatch.Groups[1].Value
            $required = $requiredMatch.Success -and $requiredMatch.Groups[1].Value -eq "true"
            $description = if ($descMatch.Success) { $descMatch.Groups[1].Value.Trim('"') } else { "" }

            $templateParams[$paramName] = @{
                Required = $required
                Description = $description
                Value = $null
            }
        }
    }

    Write-Host "  Found $($templateParams.Count) template parameters" -ForegroundColor Gray
}

# Build parameter list with smart defaults
$finalParams = @{}

# Auto-detect common parameters
$openshiftServer = (oc whoami --show-server 2>&1)

# Look for service account tokens in the namespace (try pod-health-monitor-sa first, then github-actions-sa)
$defaultToken = (oc get secrets -n $Namespace -o name 2>&1 | Select-String "pod-health-monitor-sa-token" | Select-Object -First 1)
if (-not $defaultToken) {
    $defaultToken = (oc get secrets -n $Namespace -o name 2>&1 | Select-String "github-actions-sa-token" | Select-Object -First 1)
}
if ($defaultToken) {
    $defaultToken = $defaultToken.ToString().Replace("secret/", "")
}

# Load defaults from example.secrets if environment variables not set
$secretsFile = Join-Path (Split-Path $PSScriptRoot -Parent) "example.secrets"
if (Test-Path $secretsFile) {
    Get-Content $secretsFile | Where-Object { $_ -match '^\s*([A-Z_]+)\s*=\s*(.+)$' } | ForEach-Object {
        if ($_ -match '^\s*([A-Z_]+)\s*=\s*"?([^"]+)"?') {
            $envName = $Matches[1]
            $envValue = $Matches[2]
            # Only set if not already in environment
            if (-not (Test-Path "env:$envName")) {
                Set-Item -Path "env:$envName" -Value $envValue
            }
        }
    }
}

# Apply smart defaults
$autoParams = @{
    "DEPLOY_NAMESPACE" = $Namespace
    "OPENSHIFT_SERVER" = $openshiftServer
    "OPENSHIFT_SA_TOKEN_NAME" = $defaultToken
    "MONITOR_IMAGE" = $env:MONITOR_IMAGE
}

# Merge: auto-defaults > user-provided > finalParams
foreach ($entry in $templateParams.GetEnumerator()) {
    $paramName = $entry.Key
    $paramInfo = $entry.Value

    # Priority: 1) User-provided, 2) Auto-detected, 3) Prompt if required
    if ($Parameters.ContainsKey($paramName)) {
        $finalParams[$paramName] = $Parameters[$paramName]
        Write-Host "  - $paramName = $($Parameters[$paramName]) (user-provided)" -ForegroundColor Gray
    }
    elseif ($autoParams.ContainsKey($paramName) -and $autoParams[$paramName]) {
        $finalParams[$paramName] = $autoParams[$paramName]
        Write-Host "  - $paramName = $($autoParams[$paramName]) (auto-detected)" -ForegroundColor DarkGray
    }
    elseif ($paramInfo.Required) {
        Write-Host ""
        Write-Host "  Required parameter: $paramName" -ForegroundColor Yellow
        if ($paramInfo.Description) {
            Write-Host "  Description: $($paramInfo.Description)" -ForegroundColor Gray
        }
        $value = Read-Host "  Enter value"
        $finalParams[$paramName] = $value
    }
}

# Build oc process command
if ($isTemplate) {
    Write-Host ""
    Write-Host "[INFO] Processing template with $($finalParams.Count) parameters..." -ForegroundColor Cyan

    $processArgs = @("-f", $ResourcePath)
    foreach ($param in $finalParams.GetEnumerator()) {
        $processArgs += "-p"
        $processArgs += "$($param.Key)=$($param.Value)"
    }

    # Process template
    $processedYaml = & oc process @processArgs 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Host "ERROR: Failed to process template" -ForegroundColor Red
        Write-Host $processedYaml -ForegroundColor Red
        exit 1
    }
}
else {
    # Not a template, use as-is
    $processedYaml = $yamlContent
}

# Dry-run: show processed YAML and exit
if ($DryRun) {
    Write-Host ""
    Write-Host "======================================================================" -ForegroundColor DarkGray
    Write-Host "  DRY-RUN: Processed YAML (not applied)" -ForegroundColor Yellow
    Write-Host "======================================================================" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host $processedYaml
    Write-Host ""
    exit 0
}

# Apply to cluster
Write-Host ""
Write-Host "[INFO] Applying resource to cluster..." -ForegroundColor Cyan

$applyResult = $processedYaml | oc apply -f - 2>&1
$applyExitCode = $LASTEXITCODE

Write-Host $applyResult

if ($applyExitCode -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Failed to apply resource" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "[OK] Resource applied successfully" -ForegroundColor Green

# Type-specific post-deployment actions
switch ($kind) {
    "Deployment" {
        Write-Host ""
        Write-Host "[INFO] Waiting for Deployment rollout..." -ForegroundColor Cyan

        # Extract deployment name from processed YAML
        $nameMatch = $processedYaml | Select-String -Pattern "(?ms)kind:\s*Deployment.*?name:\s*(\S+)"
        if ($nameMatch) {
            $deploymentName = $nameMatch.Matches[0].Groups[1].Value

            Write-Host "  Deployment: $deploymentName" -ForegroundColor Gray

            $rolloutResult = oc rollout status deployment/$deploymentName -n $Namespace --timeout=180s 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] Deployment rolled out successfully" -ForegroundColor Green
            }
            else {
                Write-Host "[WARN] Rollout timeout or error" -ForegroundColor Yellow
                Write-Host $rolloutResult -ForegroundColor Yellow
            }
        }
    }

    "StatefulSet" {
        Write-Host ""
        Write-Host "[INFO] Waiting for StatefulSet rollout..." -ForegroundColor Cyan

        $nameMatch = $processedYaml | Select-String -Pattern "(?ms)kind:\s*StatefulSet.*?name:\s*(\S+)"
        if ($nameMatch) {
            $statefulSetName = $nameMatch.Matches[0].Groups[1].Value

            Write-Host "  StatefulSet: $statefulSetName" -ForegroundColor Gray

            $rolloutResult = oc rollout status statefulset/$statefulSetName -n $Namespace --timeout=300s 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host "[OK] StatefulSet rolled out successfully" -ForegroundColor Green
            }
            else {
                Write-Host "[WARN] Rollout timeout or error" -ForegroundColor Yellow
                Write-Host $rolloutResult -ForegroundColor Yellow
            }
        }
    }

    "CronJob" {
        Write-Host ""
        Write-Host "[INFO] CronJob deployed - will run on schedule" -ForegroundColor Cyan
    }

    "Route" {
        Write-Host ""
        Write-Host "[INFO] Route deployed" -ForegroundColor Cyan

        # Show route URL if available
        $nameMatch = $processedYaml | Select-String -Pattern "(?ms)kind:\s*Route.*?name:\s*(\S+)"
        if ($nameMatch) {
            $routeName = $nameMatch.Matches[0].Groups[1].Value
            $routeUrl = oc get route $routeName -n $Namespace -o jsonpath='{.spec.host}' 2>&1

            if ($LASTEXITCODE -eq 0) {
                Write-Host "  URL: https://$routeUrl" -ForegroundColor Gray
            }
        }
    }

    "Template" {
        # Template already processed - check for Deployment objects
        if ($processedYaml -match "kind:\s*Deployment") {
            Write-Host ""
            Write-Host "[INFO] Template contains Deployment - checking rollout..." -ForegroundColor Cyan

            $nameMatch = $processedYaml | Select-String -Pattern "(?ms)kind:\s*Deployment.*?name:\s*(\S+)" | Select-Object -First 1
            if ($nameMatch) {
                $deploymentName = $nameMatch.Matches[0].Groups[1].Value

                Start-Sleep -Seconds 2  # Give API server time to process

                $rolloutResult = oc rollout status deployment/$deploymentName -n $Namespace --timeout=180s 2>&1

                if ($LASTEXITCODE -eq 0) {
                    Write-Host "[OK] Deployment rolled out successfully" -ForegroundColor Green
                }
                else {
                    Write-Host "[WARN] Rollout timeout or error" -ForegroundColor Yellow
                }
            }
        }
    }

    default {
        Write-Host ""
        Write-Host "[INFO] $kind deployed (no rollout verification needed)" -ForegroundColor Cyan
    }
}

Write-Host ""
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host "  [SUCCESS] DEPLOYMENT COMPLETE" -ForegroundColor Green
Write-Host "======================================================================" -ForegroundColor DarkGray
Write-Host ""
