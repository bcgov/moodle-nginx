@echo off

:: This script is used for importing a database SQL file in the local Windows environment

set sql_file_name="test-mysql-moodle_2025-05-07_09-21-15.sql.gz"
set sql_file_path="./temp/db-backups/%sql_file_name%"
set db_container_name=db-0
set db_user=root
set db_password=
set db_name=moodle
set db_host=localhost
set db_port=3306

:: Import SQL into databse
echo "Impporting SQL file: %sql_file_name% into database %db_name%"

REM Decompress and import, set encoding to utf8mb4
REM You must have gzip installed on your Windows system (or use Git Bash, or WSL)
REM If using Windows CMD, you may need to use "type" and "gzip -d -c" from Git Bash or WSL

REM Example using Git Bash or WSL:
bash -c "gzip -dc %sql_file_path% | docker exec -i %db_container_name% sh -c 'exec mysql --default-character-set=utf8mb4 -u%db_user% --password=%db_password% -h %db_host% -P %db_port% %db_name%'"

REM If you want to run a maintenance command after import, uncomment and set these variables:
REM set php_container_name=php-0
REM set maintenance_enable_command="php admin/cli/maintenance.php --enable"
REM docker exec -it %php_container_name% sh -c %maintenance_enable_command%

echo Import complete.
