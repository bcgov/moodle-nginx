<#
.SYNOPSIS
    Local Development Security Scanner for Windows/Docker Desktop

.DESCRIPTION
    Comprehensive security scanning for local Moodle development using Docker Scout.
    This script is designed for Windows developers using Docker Desktop.

    CI/CD pipelines use Trivy instead of Docker Scout for OpenShift compatibility.

.PARAMETER ImageName
    Docker image name to scan (default: moodle:local)

.PARAMETER ScanLevel
    Scan severity threshold: LOW, MEDIUM, HIGH, CRITICAL (default: HIGH)

.PARAMETER OutputFormat
    Output format: table, json, sarif, markdown (default: table)

.PARAMETER ShowRecommendations
    Display remediation recommendations

.EXAMPLE
    .\local-dev-security-scan.ps1
    Scans moodle:local with default settings

.EXAMPLE
    .\local-dev-security-scan.ps1 -ImageName "moodle:dev" -ShowRecommendations
    Scans custom image with recommendations

.EXAMPLE
    .\local-dev-security-scan.ps1 -OutputFormat json -ScanLevel CRITICAL
    Outputs JSON format, showing only critical issues

.NOTES
    Author: BCGov DevOps Team
    Requires: Docker Desktop with Docker Scout enabled
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$false)]
    [string]$ImageName = "moodle:local",

    [Parameter(Mandatory=$false)]
    [ValidateSet("LOW", "MEDIUM", "HIGH", "CRITICAL")]
    [string]$ScanLevel = "HIGH",

    [Parameter(Mandatory=$false)]
    [ValidateSet("table", "json", "sarif", "markdown")]
    [string]$OutputFormat = "table",

    [Parameter(Mandatory=$false)]
    [switch]$ShowRecommendations
)

# Color output functions
function Write-ColorOutput {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,

        [Parameter(Mandatory=$false)]
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::White
    )

    $originalColor = $Host.UI.RawUI.ForegroundColor
    $Host.UI.RawUI.ForegroundColor = $ForegroundColor
    Write-Output $Message
    $Host.UI.RawUI.ForegroundColor = $originalColor
}

function Write-Header {
    param([string]$Text)
    Write-ColorOutput "`n=== $Text ===" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Text)
    Write-ColorOutput "✅ $Text" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Text)
    Write-ColorOutput "⚠️  $Text" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Text)
    Write-ColorOutput "❌ $Text" -ForegroundColor Red
}

function Write-Info {
    param([string]$Text)
    Write-ColorOutput "ℹ️  $Text" -ForegroundColor White
}

# Main script
Write-Header "Local Development Security Scanner"

# Check for Docker
Write-Info "Checking Docker installation..."
try {
    $dockerVersion = docker version --format '{{.Server.Version}}' 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Docker is not running. Please start Docker Desktop."
        exit 1
    }
    Write-Success "Docker is running (version: $dockerVersion)"
} catch {
    Write-Error "Docker is not installed or not accessible."
    Write-Info "Install Docker Desktop from: https://www.docker.com/products/docker-desktop/"
    exit 1
}

# Check for Docker Scout
Write-Info "Checking Docker Scout availability..."
try {
    $scoutVersion = docker scout version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Docker Scout is not available."
        Write-Info ""
        Write-Info "To enable Docker Scout:"
        Write-Info "  1. Open Docker Desktop"
        Write-Info "  2. Go to Settings > Extensions"
        Write-Info "  3. Enable Docker Scout"
        Write-Info ""
        Write-Info "Alternatively, install Docker Scout CLI:"
        Write-Info "  https://docs.docker.com/scout/install/"
        exit 1
    }
    Write-Success "Docker Scout is available"
} catch {
    Write-Error "Failed to check Docker Scout status."
    exit 1
}

# Check if image exists
Write-Info "Checking if image exists: $ImageName"
try {
    $imageExists = docker image inspect $ImageName 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Image '$ImageName' not found locally."
        Write-Info ""
        Write-Info "Build the image first:"
        Write-Info "  docker-compose build"
        Write-Info ""
        Write-Info "Or specify a different image:"
        Write-Info "  .\local-dev-security-scan.ps1 -ImageName 'your-image:tag'"
        exit 1
    }
    Write-Success "Image found: $ImageName"
} catch {
    Write-Error "Failed to inspect image."
    exit 1
}

# Run Docker Scout scan
Write-Header "Running Security Scan"
Write-Info "Image: $ImageName"
Write-Info "Severity: $ScanLevel and above"
Write-Info "Format: $OutputFormat"
Write-Info ""

try {
    # Build Scout command
    $scoutArgs = @("scout", "cves")

    # Add severity filter
    if ($ScanLevel -ne "LOW") {
        $severityFilter = switch ($ScanLevel) {
            "MEDIUM"   { "medium,high,critical" }
            "HIGH"     { "high,critical" }
            "CRITICAL" { "critical" }
        }
        $scoutArgs += "--only-severity"
        $scoutArgs += $severityFilter
    }

    # Add output format
    $scoutArgs += "--format"
    $scoutArgs += $OutputFormat

    # Add image name
    $scoutArgs += $ImageName

    # Execute scan
    Write-ColorOutput "Running: docker $($scoutArgs -join ' ')" -ForegroundColor DarkGray
    Write-Info ""

    & docker @scoutArgs
    $scanExitCode = $LASTEXITCODE

    Write-Info ""

    # Interpret results
    if ($scanExitCode -eq 0) {
        Write-Success "Security scan completed"
    } else {
        Write-Warning "Security scan found vulnerabilities (exit code: $scanExitCode)"
    }

} catch {
    Write-Error "Failed to run Docker Scout scan: $_"
    exit 1
}

# Show recommendations if requested
if ($ShowRecommendations) {
    Write-Header "Remediation Recommendations"
    Write-Info "Fetching recommendations..."
    Write-Info ""

    try {
        docker scout recommendations $ImageName
    } catch {
        Write-Warning "Failed to fetch recommendations: $_"
    }
}

# Additional information
Write-Header "Additional Resources"
Write-Info "View in Docker Desktop:"
Write-Info "  Docker Desktop > Images > $ImageName > View in Scout"
Write-Info ""
Write-Info "CI/CD Pipeline:"
Write-Info "  Production builds use Trivy (not Docker Scout) for OpenShift compatibility"
Write-Info ""
Write-Info "Documentation:"
Write-Info "  .docs/security-scanning.md - Security scanning guide"
Write-Info "  .docs/vulnerability-exceptions.md - Exception management"
Write-Info ""

# Exit with scan result
exit $scanExitCode
