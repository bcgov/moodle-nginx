<#
.SYNOPSIS
    Validates version consistency between infrastructure and application dependencies locally.

.DESCRIPTION
    This script validates that infrastructure versions (example.versions.env) are compatible
    with application dependency constraints (composer.json, package.json). It provides
    immediate feedback to developers before committing changes.

.PARAMETER ProjectRoot
    The root directory of the project. Defaults to the parent of the scripts directory.

.PARAMETER ShowReport
    Generate and display a detailed markdown report of the validation results.

.PARAMETER ExitOnError
    Exit with non-zero code if validation fails (useful for pre-commit hooks).

.PARAMETER Quiet
    Minimal output - only show errors and final result.

.EXAMPLE
    .\local-validate-version-consistency.ps1

.EXAMPLE
    .\local-validate-version-consistency.ps1 -ShowReport

.EXAMPLE
    .\local-validate-version-consistency.ps1 -ExitOnError
    (For use in pre-commit hooks)

.NOTES
    Author: BC Gov DevOps Team
    Requires: PowerShell 5.1+
    See: .docs/centralized-dependency-management.md
    See: .docs/diagrams/version-management-architecture.md
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ProjectRoot = "",

    [Parameter(Mandatory=$false)]
    [switch]$ShowReport = $false,

    [Parameter(Mandatory=$false)]
    [switch]$ExitOnError = $false,

    [Parameter(Mandatory=$false)]
    [switch]$Quiet = $false
)

# ============================================================================
# CONFIGURATION
# ============================================================================

$ErrorActionPreference = "Stop"

# Determine project root
if ([string]::IsNullOrEmpty($ProjectRoot)) {
    if ([string]::IsNullOrEmpty($PSScriptRoot)) {
        # Running in ISE or other environment without PSScriptRoot
        $ProjectRoot = Get-Location
    } else {
        # Normal execution - go up one level from scripts directory
        $ProjectRoot = Split-Path -Parent $PSScriptRoot
    }
}

$Script:HasErrors = $false
$Script:HasWarnings = $false
$Script:ValidationResults = @()

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-Header {
    param([string]$Text)
    if (-not $Quiet) {
        Write-Host "`n$("=" * 80)" -ForegroundColor Cyan
        Write-Host "  $Text" -ForegroundColor Cyan
        Write-Host "$("=" * 80)" -ForegroundColor Cyan
    }
}

function Write-Success {
    param([string]$Message)
    if (-not $Quiet) {
        Write-Host "[OK] $Message" -ForegroundColor Green
    }
    $Script:ValidationResults += [PSCustomObject]@{
        Status = "Success"
        Message = $Message
    }
}

function Write-InfoMsg {
    param([string]$Message, [string]$Detail = "")
    if (-not $Quiet) {
        Write-Host "[INFO] $Message" -ForegroundColor Cyan
        if ($Detail) {
            Write-Host "   $Detail" -ForegroundColor DarkGray
        }
    }
}

function Write-Warning {
    param([string]$Message, [string]$Action = "")
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
    if ($Action) {
        Write-Host "   Action: $Action" -ForegroundColor Yellow
    }
    $Script:HasWarnings = $true
    $Script:ValidationResults += [PSCustomObject]@{
        Status = "Warning"
        Message = $Message
        Action = $Action
    }
}

function Write-ErrorMsg {
    param([string]$Message, [string]$Action = "")
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    if ($Action) {
        Write-Host "   Action: $Action" -ForegroundColor Red
    }
    $Script:HasErrors = $true
    $Script:ValidationResults += [PSCustomObject]@{
        Status = "Error"
        Message = $Message
        Action = $Action
    }
}

function Test-CommandExists {
    param([string]$Command)
    $null -ne (Get-Command $Command -ErrorAction SilentlyContinue)
}

function Get-JsonValue {
    param(
        [string]$FilePath,
        [string]$JsonPath
    )

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    try {
        $json = Get-Content $FilePath -Raw | ConvertFrom-Json
        $parts = $JsonPath -split '\.'
        $current = $json

        foreach ($part in $parts) {
            if ($current.PSObject.Properties.Name -contains $part) {
                $current = $current.$part
            } else {
                return $null
            }
        }

        return $current
    } catch {
        return $null
    }
}

function Get-EnvValue {
    param(
        [string]$FilePath,
        [string]$Key
    )

    if (-not (Test-Path $FilePath)) {
        return $null
    }

    $content = Get-Content $FilePath
    foreach ($line in $content) {
        if ($line -match "^\s*$Key\s*=\s*(.+)$") {
            return $matches[1].Trim().Trim('"').Trim("'")
        }
    }

    return $null
}

function Get-VersionFromImage {
    param([string]$ImageTag)

    # Extract version from image tags like:
    # bitnami/php-fpm:8.1.31-debian-12 → 8.1
    # node:22.19.1-alpine → 22
    if ($ImageTag -match '(\d+\.\d+)') {
        return $matches[1]
    }
    if ($ImageTag -match '(\d+)') {
        return $matches[1]
    }

    return $null
}

function Get-MinVersionFromConstraint {
    param([string]$Constraint)

    # Extract minimum version from constraints:
    # ">=8.1" → 8.1
    # "^8.1.0" → 8.1
    # "~8.1.0" → 8.1
    # ">=22.0.0" → 22
    if ($Constraint -match '(\d+\.\d+|\d+)') {
        return $matches[1]
    }

    return $null
}

function Compare-Versions {
    param(
        [string]$Version1,
        [string]$Version2
    )

    try {
        $v1Parts = $Version1 -split '\.'
        $v2Parts = $Version2 -split '\.'

        $maxLength = [Math]::Max($v1Parts.Length, $v2Parts.Length)

        for ($i = 0; $i -lt $maxLength; $i++) {
            $v1Part = if ($i -lt $v1Parts.Length) { [int]$v1Parts[$i] } else { 0 }
            $v2Part = if ($i -lt $v2Parts.Length) { [int]$v2Parts[$i] } else { 0 }

            if ($v1Part -gt $v2Part) { return 1 }
            if ($v1Part -lt $v2Part) { return -1 }
        }

        return 0
    } catch {
        # Fallback to string comparison
        if ($Version1 -eq $Version2) { return 0 }
        if ($Version1 -gt $Version2) { return 1 }
        return -1
    }
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

function Get-InfrastructureVersions {
    Write-Header "Infrastructure Versions"

    $envFile = Join-Path $ProjectRoot "example.versions.env"

    if (-not (Test-Path $envFile)) {
        Write-ErrorMsg "File not found: example.versions.env" "Create the file with infrastructure versions"
        return $null
    }

    $phpImage = Get-EnvValue -FilePath $envFile -Key "PHP_IMAGE"
    $nodeVersion = Get-EnvValue -FilePath $envFile -Key "NODE_VERSION"

    if (-not $phpImage) {
        Write-ErrorMsg "PHP_IMAGE not found in example.versions.env" "Add PHP_IMAGE=bitnami/php-fpm:X.Y.Z"
        return $null
    }

    $phpVersion = Get-VersionFromImage $phpImage
    $nodeVersionNumber = Get-VersionFromImage $nodeVersion

    if ($phpVersion) {
        Write-InfoMsg "PHP Runtime" "$phpVersion (from $phpImage)"
    } else {
        Write-Warning "Could not parse PHP version from: $phpImage"
    }

    if ($nodeVersionNumber) {
        Write-InfoMsg "Node Runtime" "$nodeVersionNumber (from $nodeVersion)"
    } else {
        Write-InfoMsg "Node Runtime" "Not configured or version not detected"
    }

    return @{
        PHPVersion = $phpVersion
        NodeVersion = $nodeVersionNumber
        PHPImage = $phpImage
        NodeVersionFull = $nodeVersion
    }
}

function Get-ComposerVersions {
    Write-Header "PHP Application Dependencies"

    $composerFile = Join-Path $ProjectRoot "config\moodle\composer.json"

    if (-not (Test-Path $composerFile)) {
        Write-InfoMsg "composer.json not found" "Skipping PHP dependency validation"
        return $null
    }

    $phpConstraint = Get-JsonValue -FilePath $composerFile -JsonPath "require.php"

    if (-not $phpConstraint) {
        Write-Warning "No PHP constraint in composer.json" "Consider adding 'php': '>=X.Y' to require section"
        return @{
            PHPConstraint = $null
        }
    }

    Write-InfoMsg "PHP Constraint" "$phpConstraint"

    # List other dependencies
    $requires = Get-Content $composerFile -Raw | ConvertFrom-Json | Select-Object -ExpandProperty require
    $packageCount = ($requires.PSObject.Properties | Where-Object { $_.Name -ne "php" }).Count

    if ($packageCount -gt 0) {
        Write-InfoMsg "Application Packages" "$packageCount dependencies managed by Composer"
    }

    return @{
        PHPConstraint = $phpConstraint
    }
}

function Get-NPMVersions {
    Write-Header "NPM Application Dependencies"

    $packageFile = Join-Path $ProjectRoot "config\lighthouse\package.json"

    if (-not (Test-Path $packageFile)) {
        Write-InfoMsg "package.json not found" "Skipping NPM dependency validation"
        return $null
    }

    $nodeConstraint = Get-JsonValue -FilePath $packageFile -JsonPath "engines.node"
    $lighthouseVersion = Get-JsonValue -FilePath $packageFile -JsonPath "dependencies.lighthouse"

    if (-not $lighthouseVersion) {
        $lighthouseVersion = Get-JsonValue -FilePath $packageFile -JsonPath "devDependencies.lighthouse"
    }

    if ($nodeConstraint) {
        Write-InfoMsg "Node Constraint" "$nodeConstraint"
    } else {
        Write-InfoMsg "Node Constraint" "Not specified in package.json engines"
    }

    if ($lighthouseVersion) {
        Write-InfoMsg "Lighthouse" "$lighthouseVersion"
    }

    # Count dependencies
    $deps = Get-Content $packageFile -Raw | ConvertFrom-Json
    [int]$depCount = 0
    if ($deps.dependencies) {
        $depsArray = @($deps.dependencies.PSObject.Properties)
        $depCount = $depCount + $depsArray.Count
    }
    if ($deps.devDependencies) {
        $devDepsArray = @($deps.devDependencies.PSObject.Properties)
        $depCount = $depCount + $devDepsArray.Count
    }

    if ($depCount -gt 0) {
        Write-InfoMsg "Application Packages" "$depCount dependencies managed by NPM"
    }

    return @{
        NodeConstraint = $nodeConstraint
        LighthouseVersion = $lighthouseVersion
    }
}

function Test-PHPCompatibility {
    param(
        [hashtable]$Infrastructure,
        [hashtable]$Composer
    )

    Write-Header "PHP Version Compatibility"

    if (-not $Infrastructure.PHPVersion) {
        Write-Warning "Cannot validate: PHP version not detected in infrastructure"
        return
    }

    if (-not $Composer -or -not $Composer.PHPConstraint) {
        Write-Warning "No PHP constraint in composer.json" "Consider adding for version validation"
        return
    }

    $minVersion = Get-MinVersionFromConstraint $Composer.PHPConstraint

    if (-not $minVersion) {
        Write-Warning "Could not parse PHP constraint: $($Composer.PHPConstraint)"
        return
    }

    $comparison = Compare-Versions $Infrastructure.PHPVersion $minVersion

    if ($comparison -ge 0) {
        Write-Success "PHP versions compatible"
        Write-InfoMsg "  Infrastructure: PHP $($Infrastructure.PHPVersion)"
        Write-InfoMsg "  Composer requires: $($Composer.PHPConstraint) (>= $minVersion)"
    } else {
        Write-ErrorMsg "PHP version mismatch" "Upgrade PHP_IMAGE in example.versions.env to >= $minVersion"
        Write-InfoMsg "  Infrastructure: PHP $($Infrastructure.PHPVersion)"
        Write-InfoMsg "  Composer requires: $($Composer.PHPConstraint) (>= $minVersion)"
    }
}

function Test-NodeCompatibility {
    param(
        [hashtable]$Infrastructure,
        [hashtable]$NPM
    )

    Write-Header "Node Version Compatibility"

    if (-not $Infrastructure.NodeVersion) {
        Write-InfoMsg "Node version not configured in infrastructure" "Skipping Node validation"
        return
    }

    if (-not $NPM -or -not $NPM.NodeConstraint) {
        Write-InfoMsg "No Node constraint in package.json engines" "Skipping Node validation"
        return
    }

    $minVersion = Get-MinVersionFromConstraint $NPM.NodeConstraint

    if (-not $minVersion) {
        Write-Warning "Could not parse Node constraint: $($NPM.NodeConstraint)"
        return
    }

    $comparison = Compare-Versions $Infrastructure.NodeVersion $minVersion

    if ($comparison -ge 0) {
        Write-Success "Node versions compatible"
        Write-InfoMsg "  Infrastructure: Node $($Infrastructure.NodeVersion)"
        Write-InfoMsg "  NPM requires: $($NPM.NodeConstraint) (>= $minVersion)"
    } else {
        Write-ErrorMsg "Node version mismatch" "Upgrade NODE_VERSION in example.versions.env to >= $minVersion"
        Write-InfoMsg "  Infrastructure: Node $($Infrastructure.NodeVersion)"
        Write-InfoMsg "  NPM requires: $($NPM.NodeConstraint) (>= $minVersion)"
    }
}

function Test-LockFileConsistency {
    Write-Header "Lock File Consistency"

    # Check composer.lock
    $composerJson = Join-Path $ProjectRoot "config\moodle\composer.json"
    $composerLock = Join-Path $ProjectRoot "config\moodle\composer.lock"

    if ((Test-Path $composerJson) -and (Test-Path $composerLock)) {
        $jsonModified = (Get-Item $composerJson).LastWriteTime
        $lockModified = (Get-Item $composerLock).LastWriteTime

        if ($lockModified -lt $jsonModified) {
            Write-Warning "composer.lock is older than composer.json" "Run: composer update"
        } else {
            Write-Success "composer.lock is up to date"
        }
    } elseif (Test-Path $composerJson) {
        Write-InfoMsg "composer.lock not found" "Run: composer install"
    }

    # Check package-lock.json
    $packageJson = Join-Path $ProjectRoot "config\lighthouse\package.json"
    $packageLock = Join-Path $ProjectRoot "config\lighthouse\package-lock.json"

    if ((Test-Path $packageJson) -and (Test-Path $packageLock)) {
        $jsonModified = (Get-Item $packageJson).LastWriteTime
        $lockModified = (Get-Item $packageLock).LastWriteTime

        if ($lockModified -lt $jsonModified) {
            Write-Warning "package-lock.json is older than package.json" "Run: npm install"
        } else {
            Write-Success "package-lock.json is up to date"
        }
    } elseif (Test-Path $packageJson) {
        Write-InfoMsg "package-lock.json not found" "Run: npm install"
    }
}

function Show-ValidationReport {
    Write-Header "Validation Report"

    $successCount = ($Script:ValidationResults | Where-Object { $_.Status -eq "Success" }).Count
    $warningCount = ($Script:ValidationResults | Where-Object { $_.Status -eq "Warning" }).Count
    $errorCount = ($Script:ValidationResults | Where-Object { $_.Status -eq "Error" }).Count

    Write-Host "`nSummary:" -ForegroundColor Cyan
    Write-Host "  [OK] Successes: $successCount" -ForegroundColor Green

    if ($warningCount -gt 0) {
        Write-Host "  [WARN] Warnings:  $warningCount" -ForegroundColor Yellow
    }

    if ($errorCount -gt 0) {
        Write-Host "  [ERROR] Errors:    $errorCount" -ForegroundColor Red
    }

    if ($warningCount -gt 0) {
        Write-Host "`nWarnings:" -ForegroundColor Yellow
        $Script:ValidationResults | Where-Object { $_.Status -eq "Warning" } | ForEach-Object {
            Write-Host "  * $($_.Message)" -ForegroundColor Yellow
            if ($_.Action) {
                Write-Host "    => $($_.Action)" -ForegroundColor DarkYellow
            }
        }
    }

    if ($errorCount -gt 0) {
        Write-Host "`nErrors:" -ForegroundColor Red
        $Script:ValidationResults | Where-Object { $_.Status -eq "Error" } | ForEach-Object {
            Write-Host "  * $($_.Message)" -ForegroundColor Red
            if ($_.Action) {
                Write-Host "    => $($_.Action)" -ForegroundColor DarkRed
            }
        }
    }

    Write-Host ""
}

function Export-ValidationReport {
    Write-Header "Generating Detailed Report"

    $reportPath = Join-Path $ProjectRoot "tmp\version-consistency-report.md"
    $tmpDir = Join-Path $ProjectRoot "tmp"

    if (-not (Test-Path $tmpDir)) {
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    }

    $infrastructure = Get-InfrastructureVersions
    $composer = Get-ComposerVersions
    $npm = Get-NPMVersions

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    $report = @"
# 📊 Version Consistency Report

**Generated:** $timestamp UTC
**Project:** bcgov/moodle-nginx
**Branch:** 950003-dev

---

## 🏗️ Infrastructure Versions (example.versions.env)

| Component | Version | Image/Configuration |
|-----------|---------|---------------------|
| **PHP Runtime** | $($infrastructure.PHPVersion) | $($infrastructure.PHPImage) |
| **Node Runtime** | $($infrastructure.NodeVersion) | $($infrastructure.NodeVersionFull) |

## 📦 Application Dependencies

### PHP Dependencies (composer.json)

| Constraint | Value | Status |
|------------|-------|--------|
| PHP Version | $($composer.PHPConstraint) | $(if ($Script:HasErrors) { "⚠️ Check required" } else { "✅ Compatible" }) |

### NPM Dependencies (package.json)

| Constraint | Value | Status |
|------------|-------|--------|
| Node Version | $($npm.NodeConstraint) | $(if ($Script:HasErrors) { "⚠️ Check required" } else { "✅ Compatible" }) |
| Lighthouse | $($npm.LighthouseVersion) | Managed by NPM |

---

## 📋 Validation Results

### Summary

* ✅ Successes: $(($Script:ValidationResults | Where-Object { $_.Status -eq "Success" }).Count)
* ⚠️  Warnings:  $(($Script:ValidationResults | Where-Object { $_.Status -eq "Warning" }).Count)
* ❌ Errors:    $(($Script:ValidationResults | Where-Object { $_.Status -eq "Error" }).Count)

### Details

"@

    foreach ($result in $Script:ValidationResults) {
        $icon = switch ($result.Status) {
            "Success" { "✅" }
            "Warning" { "⚠️" }
            "Error" { "❌" }
        }

        $report += "`n**$icon $($result.Status):** $($result.Message)"
        if ($result.Action) {
            $report += "`n  * Action: $($result.Action)"
        }
        $report += "`n"
    }

    $report += @"

---

## 🔄 Update Workflow Guidance

### If Infrastructure Needs Updating

1. Update ``example.versions.env``
2. Run validation: ``.\scripts\local-validate-version-consistency.ps1``
3. Update application constraints if needed (``composer.json``, ``package.json``)
4. Commit both infrastructure and application changes together

### If Application Dependencies Need Updating

1. Update ``composer.json`` or ``package.json``
2. Run ``composer update`` or ``npm install``
3. Run validation to check infrastructure compatibility
4. Update infrastructure if compatibility issue detected

---

## 📚 Documentation References

* [Centralized Dependency Management](.docs/centralized-dependency-management.md)
* [Version Management Architecture](.docs/diagrams/version-management-architecture.md)
* [Security Scanning Guide](.docs/security-scanning.md)

---

*Generated by local-validate-version-consistency.ps1*
*Validation ensures compatibility across infrastructure and application dependency layers*
"@

    Set-Content -Path $reportPath -Value $report -Encoding UTF8

    Write-Success "Report generated: $reportPath"

    # Try to open in default markdown viewer
    if (Test-Path $reportPath) {
        try {
            Start-Process $reportPath
            Write-InfoMsg "Report opened in default markdown viewer"
        } catch {
            Write-InfoMsg "Report saved but could not be auto-opened"
        }
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

function Main {
    Write-Host "`nVersion Consistency Validation (Local)" -ForegroundColor Cyan
    Write-Host "=" * 80 -ForegroundColor Cyan
    Write-Host "Project: $ProjectRoot" -ForegroundColor DarkGray
    Write-Host ""

    # Validate project structure
    if (-not (Test-Path (Join-Path $ProjectRoot "example.versions.env"))) {
        Write-ErrorMsg "Not a valid project root" "Could not find example.versions.env"
        return 1
    }

    # Get versions
    $infrastructure = Get-InfrastructureVersions
    $composer = Get-ComposerVersions
    $npm = Get-NPMVersions

    # Validate compatibility
    if ($infrastructure -and $composer) {
        Test-PHPCompatibility -Infrastructure $infrastructure -Composer $composer
    }

    if ($infrastructure -and $npm) {
        Test-NodeCompatibility -Infrastructure $infrastructure -NPM $npm
    }

    # Check lock files
    Test-LockFileConsistency

    # Show summary
    Show-ValidationReport

    # Generate detailed report if requested
    if ($ShowReport) {
        Export-ValidationReport
    }

    # Final result
    Write-Host "=" * 80 -ForegroundColor Cyan

    if ($Script:HasErrors) {
        Write-Host "[FAIL] VALIDATION FAILED" -ForegroundColor Red
        Write-Host "   Version compatibility issues detected - review errors above" -ForegroundColor Red
        Write-Host "   See: .docs/centralized-dependency-management.md for guidance" -ForegroundColor Yellow

        if ($ExitOnError) {
            return 1
        }
    } elseif ($Script:HasWarnings) {
        Write-Host "[WARN] VALIDATION PASSED WITH WARNINGS" -ForegroundColor Yellow
        Write-Host "   Infrastructure and application versions are compatible" -ForegroundColor Green
        Write-Host "   Some recommendations available - review warnings above" -ForegroundColor Yellow
    } else {
        Write-Host "[OK] VALIDATION SUCCESSFUL" -ForegroundColor Green
        Write-Host "   All version constraints are compatible" -ForegroundColor Green
        Write-Host "   Infrastructure and application dependencies are properly aligned" -ForegroundColor Green
    }

    Write-Host ""

    return 0
}

# Execute
$exitCode = Main
if ($ExitOnError) {
    exit $exitCode
}
