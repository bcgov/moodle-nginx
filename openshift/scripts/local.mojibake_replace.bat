@echo off
setlocal enabledelayedexpansion

:: Use underscores in variable names
set build_container_name=build-0
set php_container_name=php-0
set html_dir=/var/www/html
set moodle_cli_path=%html_dir%/admin/cli

set mojibake_script=/usr/local/bin/moodle-mojibake-replace.sh

set IMAGE_REPO=
set ENVIRONMENT=docker

:: Moodle pod

echo Starting Mojibake Replacement on %build_container_name%...
@REM docker-compose exec %build_container_name% sh -c %mojibake_script%

REM Run the find operation
docker-compose exec %build_container_name% bash -c "source /usr/local/bin/_utils.sh && moodle_content_cleanup find"

@REM REM Run the replace operation
@REM docker-compose exec build-0 bash -c "source /usr/local/bin/_utils.sh && moodle_content_cleanup replace"

echo Mojibake translations complete.
