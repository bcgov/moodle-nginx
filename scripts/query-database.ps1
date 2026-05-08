<#
.SYNOPSIS
    Query MariaDB Galera cluster using pod-mounted credentials

.DESCRIPTION
    Executes SQL queries against MariaDB Galera cluster pods, automatically
    handling authentication via environment variables (MARIADB_USER, MARIADB_ROOT_USER).

    Uses the same authentication method as openshift/scripts/utils/database.sh
    for consistency and reliability.

.PARAMETER Namespace
    Target OpenShift namespace (e.g., 950003-dev)

.PARAMETER SQL
    SQL query to execute (e.g., "SHOW VARIABLES LIKE 'wsrep_%'")

.PARAMETER User
    Database user to authenticate as:
      - moodle (default): Uses MARIADB_USER credentials
      - root: Uses MARIADB_ROOT_USER credentials

.PARAMETER Pod
    Specific pod to query (default: mariadb-galera-0)
    Examples: mariadb-galera-0, mariadb-galera-1

.PARAMETER Database
    Database to connect to (default: none - connects to server only)
    Examples: moodle, information_schema

.PARAMETER Format
    Output format:
      - table (default): Human-readable table
      - raw: Raw mysql output
      - json: JSON array (if supported by query)
      - csv: Comma-separated values

.EXAMPLE
    # Check Galera timeout configuration
    .\scripts\query-database.ps1 -Namespace 950003-dev `
        -SQL "SHOW VARIABLES LIKE 'wsrep_provider_options';"

.EXAMPLE
    # Check Galera cluster status as root
    .\scripts\query-database.ps1 -Namespace 950003-dev -User root `
        -SQL "SHOW STATUS LIKE 'wsrep_%';"

.EXAMPLE
    # Query Moodle database
    .\scripts\query-database.ps1 -Namespace 950003-dev -Database moodle `
        -SQL "SELECT COUNT(*) FROM mdl_user WHERE deleted = 0;"

.EXAMPLE
    # Get raw output for parsing
    .\scripts\query-database.ps1 -Namespace 950003-dev -Format raw `
        -SQL "SELECT VERSION();"

.NOTES
    Requires oc CLI and access to target namespace.
    Uses same authentication as openshift/scripts/utils/database.sh
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d{6}-(dev|test|prod)$')]
    [string]$Namespace,

    [Parameter(Mandatory = $true)]
    [string]$SQL,

    [Parameter(Mandatory = $false)]
    [ValidateSet('moodle', 'root')]
    [string]$User = 'moodle',

    [Parameter(Mandatory = $false)]
    [string]$Pod = 'mariadb-galera-0',

    [Parameter(Mandatory = $false)]
    [string]$Database,

    [Parameter(Mandatory = $false)]
    [ValidateSet('table', 'raw', 'csv', 'vertical')]
    [string]$Format = 'table'
)

$ErrorActionPreference = "Stop"

# Verify pod exists and is running
$podStatus = oc get pod $Pod -n $Namespace -o jsonpath='{.status.phase}' 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Pod '$Pod' not found in namespace '$Namespace'" -ForegroundColor Red
    exit 1
}

if ($podStatus -ne "Running") {
    Write-Host "ERROR: Pod '$Pod' is not Running (status: $podStatus)" -ForegroundColor Red
    exit 1
}

# Build mysql command based on user selection
$userEnvVar = if ($User -eq 'root') { 'MARIADB_ROOT_USER' } else { 'MARIADB_USER' }
$passwordFile = if ($User -eq 'root') {
    '/opt/bitnami/mariadb/secrets/mariadb-root-password'
} else {
    '/opt/bitnami/mariadb/secrets/mariadb-password'
}

# Build mysql flags based on format
$mysqlFlags = switch ($Format) {
    'table' { '' }  # Default mysql table output
    'raw' { '-sN' }  # Silent, no column names
    'csv' { '-sN' }  # We'll post-process for CSV
    'vertical' { '-E' }  # Vertical format
}

# Build database selection
$dbFlag = if ($Database) { "$Database" } else { '' }

# Execute query using simple approach that works
Write-Host "Querying $Pod as $User..." -ForegroundColor Cyan

# Build mysql command with proper flags
$mysqlCmd = "mysql"
if ($mysqlFlags) { $mysqlCmd += " $mysqlFlags" }
if ($Database) { $mysqlCmd += " $Database" }
$mysqlCmd += " -e `"$SQL`""

# Execute via bash with password loading
$output = & oc exec $Pod -n $Namespace -c mariadb-galera -- bash -c `
    "PASS=`$(cat $passwordFile | tr -d '\n\r'); mysql -u `$(printenv $userEnvVar) --password=`"`$PASS`" $mysqlFlags $dbFlag -e '$SQL'" 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Host "ERROR: Query failed" -ForegroundColor Red
    Write-Host $output -ForegroundColor Red
    exit 1
}

# Format output based on requested format
if ($Format -eq 'csv') {
    # Convert tab-separated to comma-separated
    $output -replace "`t", ","
} else {
    $output
}
