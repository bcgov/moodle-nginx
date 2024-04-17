@echo off

:: This script is used for tetsing upgrade process in local Windows environment
:: This will put moodle into maintenance mode, copy files from build to deploy location
:: It will uninstall any missing (removed) plugins prior to upgrade
:: It will run any database upgrades
:: It will also run cron and purge caches

set html-dir="/var/www/html"
set moodle-cli-path=%html-dir%/admin/cli
set moodle-service-name="moodle"
set php-container-name="moodle-nginx-php-1"

set purge-plugins-command="php %moodle-cli-path%/uninstall_plugins.php --purge-missing --run"
set maintenance-enable-command="php %moodle-cli-path%/maintenance.php --enable"
set maintenance-disable-command="php %moodle-cli-path%/maintenance.php --disable"
set upgrade-command="php %moodle-cli-path%/upgrade.php --non-interactive"
set cron-command="php %moodle-cli-path%/cron.php"

:: Build / upgrade moodle
:: PHP pod
echo "Enabble maintenance mode..."
docker exec -it %php-container-name% sh -c %maintenance-enable-command%

SLEEP 10

:: Moodle pod (will automatically copy files on launch)
echo "Starting moodle pod... copying files from build to deploy location"
docker-compose up -d %moodle-service-name%

SLEEP 10

:loop
  timeout /t 1 >nul
  docker-compose ps --all --status=exited | find /i "moodle-nginx-moodle"
if errorlevel 1 goto :loop

echo "Moodle file deployment complete."

:: PHP Pod
echo "Purge any missing plugins..."
docker exec -it %php-container-name% sh -c %purge-plugins-command%

echo "Running Moodle upgrades..."
docker exec -it %php-container-name% sh -c %upgrade-command%

echo "Purge caches..."
docker exec -it %php-container-name% sh -c %purge-command%

echo "Disable maintenance mode..."
docker exec -it %php-container-name% sh -c %maintenance-disable-command%

:: Cron must be run outside of maintenance mode
echo "Run cron..."
docker exec -it %php-container-name% sh -c %cron-command%

echo "Upgrade complete."
