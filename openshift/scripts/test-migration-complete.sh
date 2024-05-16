#!/bin/bash

text_to_find='Moodle frontpage.'
file='/var/www/html/index.php'

echo 'Waiting for file copy to complete...'

until grep -q "${text_to_find}" "${file}"
do
  sleep 5s
done

echo 'File copy complete.'
