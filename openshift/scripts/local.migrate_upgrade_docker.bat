@echo off
setlocal enabledelayedexpansion

:: Use underscores in variable names
set build_container_name=build-0
set php_container_name=php-0
set html_dir=/var/www/html
set moodle_cli_path=%html_dir%/admin/cli

set enable_maintenance_command=/usr/local/bin/enable-maintenance.sh
set migrate_build_files_command=/usr/local/bin/migrate-build-files.sh
set test_migration_complete_command=/usr/local/bin/test-migration-complete.sh
set upgrade_command=/usr/local/bin/moodle-upgrade.sh

set IMAGE_REPO=

:: PHP pod
echo Enabble maintenance mode on %php_container_name%...
docker exec -it %php_container_name% sh -c %enable_maintenance_command%

SLEEP 2

:: Moodle pod
echo Checking if moodle pod (%build_container_name%) is already running...

docker compose ps --status=running > temp_ps.txt 2>&1
findstr /i "%build_container_name%" temp_ps.txt >nul
if errorlevel 1 echo Starting moodle pod (%build_container_name%)... & docker compose up -d %build_container_name%
if not errorlevel 1 echo Moodle pod (%build_container_name%) is already running. Skipping start.
del temp_ps.txt


SLEEP 5

echo Migrating files (%build_container_name%)...
docker-compose exec %build_container_name% sh -c %migrate_build_files_command%

SLEEP 30

echo Testing for completion of file migration...

docker-compose exec %build_container_name% sh -c %test_migration_complete_command% | find /i "moodleappdir"
if errorlevel 1 (
    echo File migration failed. Please check the logs for more details.
    exit /b 1
) else (
    echo File migration completed successfully.
)

SLEEP 2

:: PHP pod
echo Upgrading Moodle database (%php_container_name%)...
docker exec -it %php_container_name% sh -c %upgrade_command%

echo Upgrade complete.
