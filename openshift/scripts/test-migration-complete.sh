#!/bin/bash

text_to_find='Moodle frontpage.'
file='/var/www/html/index.php'
src_dir='/app/public'
dest_dir='/var/www/html'

echo 'Waiting for file copy to complete...'

until grep -q "${text_to_find}" "${file}"
do
  sleep 5s
done

echo 'File copy complete.'

echo 'Verifying file copy...'

echo ""

echo "Comparing files in source and destination directories..."
(rsync -rcn --out-format="%n" $src_dir $dest_dir && rsync -rcn --out-format="%n" $dest_dir $src_dir) | sort | uniq

# Count the number of files in source and destination directories
# src_count=$(find $src_dir -type f | wc -l)
# dest_count=$(find $dest_dir -type f | wc -l)
src_count=$(find $src_dir -type f ! -name ".*" ! -type l | wc -l)
dest_count=$(find $dest_dir -type f ! -name ".*" ! -type l | wc -l)

echo ""

# Compare the file counts
if [ $src_count -eq $dest_count ]; then
  echo "All files have been copied (count of src and dest match)."
else
  echo "File copy is not complete. Source has $src_count files, but destination has $dest_count files."
  echo "Finding missing files..."
  cd $src_dir && find . -type f | sort > /tmp/src_files
  cd $dest_dir && find . -type f | sort > /tmp/dest_files
  # diff /tmp/src_files /tmp/dest_files
  diff -qr /tmp/src_files /tmp/dest_files -x ".git"
  rm /tmp/src_files /tmp/dest_files

  # exit 1 # Don't exit here
fi

# Find files in the destination directory that don't have read, write, and execute permissions for the owner
incorrect_permissions_files=$(find $dest_dir -type d ! -perm 755 -o -type f ! -perm 644)

echo ""

# Check if any files were found
if [ -n "$incorrect_permissions_files" ]; then
  echo "The following files in the moodle directory do not have the correct permissions:"
  echo "$incorrect_permissions_files"
  # exit 1 # Don't exit here
else
  echo "All files in the destination directory have the correct permissions."
fi

echo ""

echo "File copy and verification complete."
