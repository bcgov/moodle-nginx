<?php
define('CLI_SCRIPT', true);
require_once('/var/www/html/config.php');
$courseid = $argv[1] ?? '';
$newtag = $argv[2] ?? '';

if (!$courseid || !$newtag) {
  exit(1);
}
// Remove all migration-related tags, add new one
$tags = ['Testing', 'Production', 'Transferred-Testing', 'Transferred-Production'];
foreach ($tags as $tag) {
  $tagrec = $DB->get_record('tag', ['name' => $tag]);
  if ($tagrec) {
    $DB->delete_records('tag_instance', ['itemid' => $courseid, 'tagid' => $tagrec->id, 'itemtype' => 'course']);
  }
}
require_once($CFG->dirroot . '/tag/lib.php');
tag_set('course', $courseid, [$newtag]);
