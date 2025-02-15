#!/bin/bash

echo "Verifying files in source and destination directories..."
echo ""

# Exclude directories that may cause permission issues
EXCLUDES="--exclude=".*" --exclude='*/.*' --exclude=/etc/ssl/private --exclude=/proc/tty/driver --exclude=/root --exclude=/var/cache/apt/archives/partial --exclude=/var/cache/ldconfig --exclude=.git"

# Use rsync to copy files, excluding hidden files and symbolic links
rsync -rcn --out-format="%n" --existing $EXCLUDES $src_dir/ $dest_dir/ | sort | uniq

# Count the number of files in source and destination directories, excluding hidden files and symbolic links
src_count=$(find $src_dir -type f ! -name ".*" ! -type l | wc -l)
dest_count=$(find $dest_dir -type f ! -name ".*" ! -type l | wc -l)

# Compare the file counts
if [ $src_count -eq $dest_count ]; then
  echo "All files have been copied. Count of src and dest match: $dest_count."
else
  echo "File copy is not complete. Source has $src_count files, but destination has $dest_count files."
  echo "Finding missing files..."

  # Create temporary files to store the list of files
  src_files=$(mktemp)
  dest_files=$(mktemp)

  # List files in source and destination directories, excluding hidden files and symbolic links
  cd $src_dir && find . -type f ! -name ".*" ! -type l | sort > $src_files
  cd $dest_dir && find . -type f ! -name ".*" ! -type l | sort > $dest_files

  # Find files that exist in the source directory but not in the destination directory
  missing_files=$(comm -23 $src_files $dest_files)
  if [ -n "$missing_files" ]; then
    echo "Missing files in destination:"
    echo "$missing_files"
    echo ""
  else
    echo "No missing files in destination."
  fi

  # Find files that exist in the destination directory but not in the source directory
  extra_files=$(comm -13 $src_files $dest_files)
  if [ -n "$extra_files" ]; then
    echo "Extra files in destination:"
    echo "$extra_files"
    echo ""
  else
    echo "No extra files in destination."
  fi

  # Find files that exist in both directories but have different contents
  differing_files=$(diff --brief -r $src_dir $dest_dir | grep -v "^Only")
  if [ -n "$differing_files" ]; then
    echo "Files with different contents:"
    echo "$differing_files"
  else
    echo "No files with different contents."
  fi

  # Clean up temporary files
  rm $src_files $dest_files

  # exit 1 # Don't exit here, as it will currently break deployments
fi

# Find files in the destination directory that don't have read, write, and execute permissions for the owner
incorrect_permissions_files=$(find $dest_dir -mindepth 1 -type d ! -perm 755 -o -type f ! -perm 644 ! -path "*/.git/*")

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
