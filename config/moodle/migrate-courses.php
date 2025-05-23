<?php
// Usage: php migrate-courses.php [target_env]
// Example: php migrate-courses.php test

define('CLI_SCRIPT', true);
require_once('config.php');

$target_env = $argv[1] ?? '';
if (!$target_env) {
    echo "Usage: php migrate-courses.php [test|prod]\n";
    exit(1);
}

$tag_to_search = '';
switch ($target_env) {
    case 'test':
        $tag_to_search = 'Testing';
        $dest_namespace = str_replace('-dev', '-test', $CFG->wwwroot);
        break;
    case 'prod':
        $tag_to_search = 'Production';
        $dest_namespace = str_replace('-test', '-prod', $CFG->wwwroot);
        break;
    default:
        echo "Unknown target environment: $target_env\n";
        exit(1);
}

echo "Searching for courses tagged: $tag_to_search\n";

// Find tag id
$tag = $DB->get_record('tag', ['name' => $tag_to_search]);
if (!$tag) {
    echo "No tag found: $tag_to_search\n";
    exit(0);
}

// Find courses with this tag
$sql = "SELECT c.id, c.fullname
          FROM {course} c
          JOIN {tag_instance} ti ON ti.itemid = c.id
         WHERE ti.tagid = ? AND ti.itemtype = 'course'";
$courses = $DB->get_records_sql($sql, [$tag->id]);

if (!$courses) {
    echo "No courses found with tag: $tag_to_search\n";
    exit(0);
}

$backup_dir = '/tmp/file-backups/transfer';
if (!is_dir($backup_dir)) {
    mkdir($backup_dir, 0777, true);
}

foreach ($courses as $course) {
    echo "Backing up course: {$course->fullname} (ID: {$course->id})\n";
    $cmd = "php /var/www/html/admin/cli/backup.php --courseid={$course->id} --destination={$backup_dir}";
    passthru($cmd);
}

// Transfer backups to the next environment (example using scp)
$remote_host = "user@{$dest_namespace}:/tmp/file-backups/transfer";
echo "Transferring backups to $remote_host\n";
passthru("scp {$backup_dir}/*.mbz $remote_host");

echo "Migration complete.\n";
