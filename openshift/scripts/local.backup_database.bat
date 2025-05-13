@echo off

:: This script exports a database SQL file from the container in the local Windows environment

setlocal enabledelayedexpansion

set local_backup_file_path=./temp/db-backups
set db_container_name=db-0
set db_user=root
set db_password=
set db_name=moodle
set db_host=localhost
set db_port=3306

:: Get current date-time stamp in format yyyy-mm-dd_hh-mm-ss
for /f %%a in ('wmic os get localdatetime ^| find "."') do set dt=%%a
set datetime=%dt:~0,4%-%dt:~4,2%-%dt:~6,2%_%dt:~8,2%-%dt:~10,2%

set sql_file_name=local-mysql-%db_name%_%datetime%.sql.gz
set sql_file_path=%local_backup_file_path%/%sql_file_name%

echo Backing up database: %db_name% to file: %sql_file_name%

REM Export and compress the database using utf8mb4 encoding
REM You must have gzip installed on your Windows system (or use Git Bash, or WSL)
REM This example uses Git Bash or WSL for gzip

bash -c "docker exec %db_container_name% sh -c 'exec mysqldump --default-character-set=utf8mb4 -u%db_user% --password=%db_password% -h %db_host% -P %db_port% %db_name%' | gzip > %sql_file_path%"

echo Export complete.
