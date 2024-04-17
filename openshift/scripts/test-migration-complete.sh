#!/bin/bash

canary_line='Moodle frontpage.'
file='/var/www/html/index.php'

echo 'Waiting for file copy to complete...'

until grep -q "${canary_line}" "${file}"
do
  sleep 5s
done

echo 'File copy complete.'
