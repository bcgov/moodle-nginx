<?php
define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');
$courseid = $argv[1] ?? '';
$newtag = $argv[2] ?? '';

if (!$courseid || !$newtag) {
  exit(1);
}
// Remove all migration-related tags, add new one
require_once($CFG->dirroot . '/tag/lib.php');

$tags = ['Testing', 'Production', 'Transferred-Testing', 'Transferred-Production'];
foreach ($tags as $tag) {
  if ($tag !== $newtag) {
    core_tag_tag::remove_item_tag('core', 'course', $courseid, $tag);
  }
}

// Add the new tag
core_tag_tag::set_item_tags('core', 'course', $courseid, context_course::instance($courseid), [$newtag]);
