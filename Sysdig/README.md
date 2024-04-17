# Integration between Sysdig and MySQL

## Setup Sysdig (pointing to 950003-dev > mysql > k8s_statefulset)

https://app.sysdigcloud.com/#/integrations/prometheus?sortOn=entityName&workloadId=silver%3A%3A950003-dev%3A%3Amysql%3A%3Ak8s_statefulset

## Setup OpenShift

### Add exporter user for Sysdig integration with mysql

CREATE USER 'exporter' IDENTIFIED BY 'moodle' WITH MAX_USER_CONNECTIONS 3;
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter';

### Create secret for mysql-exporter

oc create secret -n 950003-dev generic mysql-exporter --from-file=.my.cnf=./Sysdig/mysql-exporter.cnf

### Install mysql-exporter helm chart

helm install -n 950003-dev -f ./Sysdig/helm-values-dev.yml --repo https://sysdiglabs.github.io/integrations-charts 950003-dev-mysql mysql-exporter

## Complete Sysdig setup / validation
