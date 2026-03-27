#!/bin/bash
#==============================================================================
# mariadb-prestop.sh
#==============================================================================
# PURPOSE:
#   PreStop lifecycle hook for MariaDB Galera StatefulSet pods. Ensures
#   graceful shutdown of MariaDB service before pod termination, preventing
#   split-brain scenarios and maintaining cluster integrity.
#
# GRACEFUL SHUTDOWN PROCESS:
#   1. Detect if pod is primary (master) node
#   2. If primary: Disable replication (wsrep_on=OFF)
#   3. Wait for replication to stop (5 seconds)
#   4. Shutdown MariaDB service (mysqladmin shutdown)
#   5. Wait configured period before exiting
#
# SPLIT-BRAIN PREVENTION:
#   - Disabling wsrep_on prevents partial cluster operations
#   - Waiting period allows other nodes to detect departure
#   - Clean shutdown prevents inconsistent cluster state
#
# CONFIGURATION:
#   WAIT_PERIOD              - Seconds to wait before exit (default: 60)
#                              Set to 0 in production for faster restarts
#                              Set to 60+ in dev/test for failover testing
#
# EXECUTION CONTEXT:
#   - Runs as: PreStop hook in StatefulSet pod spec
#   - Triggered: Before pod termination (scale down, rolling update, delete)
#   - User: root (requires MySQL root password)
#   - Environment: MARIADB_ROOT_PASSWORD must be set
#
# USAGE:
#   # Applied via StatefulSet patch
#   See: config/mariadb/mariadb-galera-prestop-patch.json
#
#   # Manual execution (testing only)
#   export MARIADB_ROOT_PASSWORD="your-password"
#   export WAIT_PERIOD=60
#   ./openshift/scripts/mariadb-prestop.sh
#
# RELATED DOCS:
#   - Patch Configuration: ../../config/mariadb/mariadb-galera-prestop-patch.json
#   - Deployment: ./deploy-mariadb-galera.sh
#   - Architecture: ../../docs/galera-monitoring-solution.md
#   - Troubleshooting: ../../docs/manual-galera-troubleshooting.md
#==============================================================================

# Set the waiting period before the pod is terminated
# For failover testing purposes (can/should set to 0 in prod)
WAIT_PERIOD=60  # in seconds

# Function to gracefully stop MariaDB service
graceful_shutdown() {
  echo "Initiating graceful shutdown of MariaDB service..."

  # Check if the current pod is the primary (master) pod
  if mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "SHOW STATUS LIKE 'wsrep_local_state_comment';" | grep -q "Synced"; then
    echo "This pod is the primary (master) pod. Proceeding with shutdown..."

    # Set wsrep_on to OFF to stop replication
    mysql -u root -p"$MARIADB_ROOT_PASSWORD" -e "SET GLOBAL wsrep_on=OFF;"

    # Wait for a few seconds to allow replication to stop
    sleep 5

    # Shutdown MariaDB service
    mysqladmin -u root -p"$MARIADB_ROOT_PASSWORD" shutdown
  else
    echo "This pod is not the primary (master) pod. Proceeding with shutdown..."

    # Shutdown MariaDB service
    mysqladmin -u root -p"$MARIADB_ROOT_PASSWORD" shutdown
  fi

  echo "MariaDB service has been gracefully stopped."
}

# Run the graceful shutdown function
graceful_shutdown

# Introduce a waiting period before exiting
WAIT_MINUTES=$((WAIT_PERIOD / 60))
echo "Waiting for $WAIT_PERIOD seconds ($WAIT_MINUTES minutes) before exiting..."
sleep $WAIT_PERIOD

echo "PreStop hook script completed. Exiting..."
