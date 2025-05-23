<?php
// Usage: php find-courses-with-tag.php [tag]
// Example: php find-courses-with-tag.php 'Testing'
// This script finds all courses with a specific tag
// in Moodle and outputs their IDs.

define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');

$tag = $argv[1] ?? '';

if (!$tag) {
  exit(1);
}

$tagrec = $DB->get_record('tag', ['name' => $tag]);

if (!$tagrec) {
  exit(0);
}

$sql = "SELECT c.id FROM {course} c JOIN {tag_instance} ti ON ti.itemid = c.id WHERE ti.tagid = ? AND ti.itemtype = 'course'";
$courses = $DB->get_records_sql($sql, [$tagrec->id]);

foreach ($courses as $c) {
  echo $c->id . "\n";
}
