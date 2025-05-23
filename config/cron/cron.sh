#!/bin/bash
backup_dir="/tmp/file-backups/moodledata"
src_dir="/var/www/moodledata"

mkdir -p "$backup_dir"

while true; do
  /usr/local/bin/php /var/www/html/admin/cli/cron.php >&1

  # Create daily backup if not already done
  today=$(date +"%Y-%m-%d")
  backup_file="${backup_dir}/${today}-moodledata.tar.gz"
  if [ ! -f "$backup_file" ]; then
    echo "Creating backup: $backup_file"
    tar -czf "$backup_file" -C "$src_dir" .
    # Prune old backups, keep only the most recent
    echo "Pruning old backups..."
    ls -1t "$backup_dir"/*-moodledata.tar.gz | tail -n +2 | xargs -r rm --
  fi

  sleep 60
done
