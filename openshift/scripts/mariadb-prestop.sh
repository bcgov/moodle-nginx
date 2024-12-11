#!/bin/bash

# Set the waiting period before the pod is terminated
# For failover testing purposes (can/should set to 0 in prod)
WAIT_PERIOD=600  # in seconds

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
