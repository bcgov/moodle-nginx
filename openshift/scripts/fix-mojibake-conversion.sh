#!/bin/bash

DB="moodle"
USER="root"

# BACKUP_FILE=./tmp/db-backups/950003-prod/2025-06-13/mysql-moodle_2025-06-13_08-49-35.sql/mysql-moodle_2025-06-13_08-49-35.sql
# BACKUP_FILE=./tmp/db-backups/allan.sql
BACKUP_FILE=./tmp/db-backups/moodle_allan_utf8mb4_2025-06-17.1733.sql.gz

if [ ! -f "$BACKUP_FILE" ]; then
  echo "Backup file $BACKUP_FILE does not exist. Exiting..."
  exit 1
fi

echo "Emptying database: $DB..."
mysql -u $USER $DB -e "DROP DATABASE IF EXISTS $DB; CREATE DATABASE $DB CHARACTER SET latin1 COLLATE latin1_swedish_ci;"

echo "Restoring database ($DB) from backup..."
echo "Using backup file: $BACKUP_FILE"
if [[ "$BACKUP_FILE" == *.gz ]]; then
  echo "Detected .gz extension, using gunzip for import..."
  gunzip -c "$BACKUP_FILE" | mysql -u "$USER" "$DB"
elif file "$BACKUP_FILE" | grep -q 'gzip compressed'; then
  echo "Detected gzip-compressed file by file magic, using gunzip for import..."
  gunzip -c "$BACKUP_FILE" | mysql -u "$USER" "$DB"
else
  echo "Detected plain SQL file, importing directly..."
  mysql -u "$USER" "$DB" < "$BACKUP_FILE"
fi

# Backup all tables except if they match a specific pattern: LIKE '%backup_20250617%'
# mysqldump -u $USER -p $DB $(mysql -u $USER -N -e "SHOW TABLES LIKE '%backup_20250617%'" $DB | awk '{print "--ignore-table="$DB"."$1}')

# echo "Generating SQL to convert all tables to latin1_swedish_ci..."
# mysql -u $USER -N -e "SELECT CONCAT('ALTER TABLE \`', TABLE_NAME, '\` CONVERT TO CHARACTER SET latin1 COLLATE latin1_swedish_ci;') FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$DB';" > to_latin1.sql

# echo "Converting all tables to latin1_swedish_ci..."
# mysql -u $USER -D $DB < to_latin1.sql

# echo "Verifying current table collations..."
# mysql -u $USER -e "SELECT TABLE_NAME, TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='$DB';"

# echo "Generating SQL to convert all tables to utf8mb4_unicode_ci..."
# mysql -u $USER -N -e "SELECT CONCAT('ALTER TABLE \`', TABLE_NAME, '\` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;') FROM information_schema.TABLES WHERE TABLE_SCHEMA = '$DB';" > to_utf8mb4.sql

# echo "Converting all tables to utf8mb4_unicode_ci..."
# mysql -u $USER -D $DB < to_utf8mb4.sql

# echo "Updating database default charset/collation..."
# # mysql -u $USER -e "ALTER DATABASE $DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
# mysql -u $USER -e "ALTER DATABASE $DB CHARACTER SET latin1 COLLATE latin1_swedish_ci;"

echo "Done! Please check data for correct encoding."
