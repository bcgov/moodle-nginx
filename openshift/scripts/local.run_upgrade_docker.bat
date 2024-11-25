@echo off

:: This script is used for tetsing upgrade process in local Windows environment
:: This will send a request to each pod (php, moodle) to run the installed shell script
:: The combines scripts will
::  1. Put moodle into maintenance mode
::  2. Copy files from build to deploy location
::  3. Run moodle upgrades
:: It will uninstall any missing (removed) plugins prior to upgrade
:: It will run any database upgrades
:: It will also run cron and purge caches

set html-dir=/var/www/html
set moodle-cli-path=%html-dir%/admin/cli
set moodle-service-name=php
set php-container-name=moodle-nginx-php-1

set enable-maintenance-command=/usr/local/bin/enable-maintenance.sh
set migrate-build-files-command=/usr/local/bin/migrate-build-files.sh
set test-migration-complete-command=/usr/local/bin/test-migration-complete.sh
set upgrade-command=/usr/local/bin/moodle-upgrade.sh

:: Build / upgrade moodle
:: PHP pod
echo Enabble maintenance mode on %php-container-name%...
docker exec -it %php-container-name% sh -c %enable-maintenance-command%

SLEEP 10

:: Moodle pod
echo Starting moodle pod (%moodle-service-name%)...
docker-compose up -d %moodle-service-name%

SLEEP 10

echo Migrating files (%moodle-service-name%)...
docker-compose exec %moodle-service-name% sh -c %migrate-build-files-command%

SLEEP 30

echo Testing for completion of file migration...

:: Test for file migration to complete (once config.php exists)
:loop
  timeout /t 1 >nul
  docker-compose exec %moodle-service-name% sh -c %test-migration-complete-command%  | find /i "moodleappdir"
if errorlevel 1 goto :loop

echo File migration complete.

SLEEP 2

:: PHP pod
echo Upgrading Moodle database (%php-container-name%)...
docker exec -it %php-container-name% sh -c %upgrade-command%

echo Upgrade complete.
