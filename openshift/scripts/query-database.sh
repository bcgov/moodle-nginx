#!/bin/bash
#==============================================================================
# query-database.sh
#==============================================================================
# PURPOSE:
#   Execute SQL queries against MariaDB Galera cluster with automatic
#   authentication handling. Reuses get_mariadb_env_vars() from database.sh
#   for consistent, reliable credential management.
#
# USAGE:
#   # Default: query as moodle user
#   bash query-database.sh "SHOW VARIABLES LIKE 'wsrep_%';"
#
#   # Query as root
#   bash query-database.sh -User root "SHOW STATUS LIKE 'wsrep_%';"
#
#   # Query specific database
#   bash query-database.sh -Database moodle "SELECT COUNT(*) FROM mdl_user;"
#
#   # Query specific pod
#   bash query-database.sh -Pod mariadb-galera-1 "SELECT @@hostname;"
#
#   # Raw output (no table formatting)
#   bash query-database.sh -Format raw "SELECT VERSION();"
#
# AUTHENTICATION:
#   Automatically loads credentials via get_mariadb_env_vars() from database.sh
#   - moodle user: MARIADB_USER + MARIADB_PASSWORD (from secrets)
#   - root user: MARIADB_ROOT_USER + MARIADB_ROOT_PASSWORD (from secrets)
#
# RELATED:
#   - openshift/scripts/utils/database.sh (credential handling)
#   - scripts/query-database.ps1 (PowerShell wrapper for local use)
#==============================================================================

# Universal _utils.sh loader
for _util_path in \
  "$(dirname "${BASH_SOURCE[0]}")/_utils.sh" \
  "/scripts/_utils.sh" \
  "/usr/local/bin/_utils.sh" \
  "./openshift/scripts/_utils.sh"; do
  [[ -f "$_util_path" ]] && source "$_util_path" && break
done
[[ "$(type -t log_info)" != "function" ]] && echo "FATAL: Cannot locate _utils.sh" && exit 1

# Default values
USER="moodle"
POD_NAME="${DB_DEPLOYMENT_NAME:-mariadb-galera}-0"
DATABASE=""
FORMAT="table"
SQL_QUERY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    -User|--user)
      USER="$2"
      shift 2
      ;;
    -Pod|--pod)
      POD_NAME="$2"
      shift 2
      ;;
    -Database|--database|-DB|--db)
      DATABASE="$2"
      shift 2
      ;;
    -Format|--format)
      FORMAT="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1"
      exit 1
      ;;
    *)
      # First non-flag argument is the SQL query
      SQL_QUERY="$1"
      shift
      ;;
  esac
done

# Validate required parameters
if [[ -z "$SQL_QUERY" ]]; then
  echo "ERROR: No SQL query provided"
  echo ""
  echo "Usage:"
  echo "  $0 [OPTIONS] \"SQL QUERY\""
  echo ""
  echo "Options:"
  echo "  -User <moodle|root>     Database user (default: moodle)"
  echo "  -Pod <pod-name>         Pod to query (default: mariadb-galera-0)"
  echo "  -Database <db-name>     Database to use (optional)"
  echo "  -Format <table|raw|vertical>  Output format (default: table)"
  echo ""
  echo "Examples:"
  echo "  $0 \"SHOW VARIABLES LIKE 'wsrep_%';\""
  echo "  $0 -User root \"SHOW STATUS LIKE 'wsrep_%';\""
  echo "  $0 -Database moodle \"SELECT COUNT(*) FROM mdl_user;\""
  exit 1
fi

# Load MariaDB credentials using existing utility function
# This sets: MARIADB_USER, MARIADB_PASSWORD, MARIADB_ROOT_USER, MARIADB_ROOT_PASSWORD
get_mariadb_env_vars "$POD_NAME"

# Select credentials based on user
if [[ "$USER" == "root" ]]; then
  DB_USER="$MARIADB_ROOT_USER"
  DB_PASS="$MARIADB_ROOT_PASSWORD"
else
  DB_USER="$MARIADB_USER"
  DB_PASS="$MARIADB_PASSWORD"
fi

# Validate credentials were loaded
if [[ -z "$DB_USER" || -z "$DB_PASS" ]]; then
  log_error "Failed to load database credentials for user: $USER"
  exit 1
fi

# Build mysql command flags based on format
MYSQL_FLAGS=""
case "$FORMAT" in
  raw)
    MYSQL_FLAGS="-sN"  # Silent, no column names
    ;;
  vertical)
    MYSQL_FLAGS="-E"  # Vertical format
    ;;
  table)
    MYSQL_FLAGS=""  # Default table format
    ;;
  *)
    log_warn "Unknown format '$FORMAT', using default table format"
    MYSQL_FLAGS=""
    ;;
esac

# Build database selection
DB_SELECT=""
if [[ -n "$DATABASE" ]]; then
  DB_SELECT="$DATABASE"
fi

# Execute query
log_info "Querying $POD_NAME as $DB_USER..."

if oc exec -n "$DEPLOY_NAMESPACE" "$POD_NAME" -c mariadb-galera -- \
  mysql -u "$DB_USER" -p"$DB_PASS" $MYSQL_FLAGS $DB_SELECT -e "$SQL_QUERY"; then
  log_success "Query completed successfully"
else
  log_error "Query failed (exit code: $?)"
  exit 1
fi
