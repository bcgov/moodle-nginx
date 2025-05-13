<?php
// filepath: fix-mojibake.php

if (function_exists('mb_internal_encoding')) {
  mb_internal_encoding('UTF-8');
}
if (function_exists('mb_http_output')) {
  mb_http_output('UTF-8');
}
ini_set('default_charset', 'UTF-8');

// Ensure Moodle knows we are running from CLI
define('CLI_SCRIPT', false);

require_once('config.php'); // Use Moodle's DB config

echo "Test utf-8 encoding: “ ” ‘ ’ … ™ © ®\n";

// --- Mojibake replacements array (garbled => intended) ---
$mojibake_replacements = [
  'â€œ' => '“',
  'â€' => '”',
  'Ã¢â‚¬Ëœ' => "'",
  'Ã¢â‚¬â„¢' => "'",
  'â€˜' => "'",
  'â€™' => "'",
  'â€“' => '-',
  'â€”' => '-',
  'â€¦' => '…',
  'â€' => '†',
  'â€¡' => '‡',
  'â„¢' => '™',
  'Â' => '',
  'Â©' => '©',
  'Â®' => '®',
  'Â«' => '«',
  'Â»' => '»',
  'Â±' => '±',
  'Â£' => '£',
  'Â¢' => '¢',
  'Â¥' => '¥',
  'Â§' => '§',
  'Â¨' => '¨',
  'Âª' => 'ª',
  'Âº' => 'º',
  'Âœ' => 'œ',
  'Â¼' => '¼',
  'Â½' => '½',
  'Â¾' => '¾'
];

// Sort mojibake replacements by length of the garbled string, descending.
// To avoid partial replacements, we want to replace longer strings first.
uksort($mojibake_replacements, function ($a, $b) {
  return strlen($b) <=> strlen($a);
});

// --- Table/column targets array ---
$moodle_content_columns = [
  // Format: [table, column, id_column, link_pattern]
  ['course', 'summary', 'id', '/course/view.php?id=%d'],
  ['course', 'fullname', 'id', '/course/view.php?id=%d'],
  ['course', 'shortname', 'id', '/course/view.php?id=%d'],
  ['course', 'summaryformat', 'id', '/course/view.php?id=%d'],
  ['course_sections', 'summary', 'id', '/course/section.php?section=%d'],
  ['page', 'content', 'id', '/mod/page/view.php?id=%d'],
  ['label', 'intro', 'id', '/mod/label/view.php?id=%d'],
  ['forum_posts', 'message', 'id', '/mod/forum/discuss.php?d=%d'],
  ['assign', 'intro', 'id', '/mod/assign/view.php?id=%d'],
  ['book_chapters', 'content', 'id', '/mod/book/view.php?chapterid=%d'],
];

// --- Helper: Generate a link to the content ---
function make_link($table, $id, $link_pattern, $CFG) {
  if (!$link_pattern) {
    return '';
  }

  return $CFG->wwwroot . sprintf($link_pattern, $id);
}

// --- FIND FUNCTION ---
function find_mojibake($DB, $mojibake_replacements, $moodle_content_columns, $CFG) {
  $count = 0;
  foreach ($moodle_content_columns as $colinfo) {
    list($table, $column, $idcol, $link_pattern) = $colinfo;
    echo "<br />";
    echo "<br />";
    echo "Searching $table.$column ...\n";
    echo "<br />";
    echo "<br />";
    foreach ($mojibake_replacements as $garbled => $intended) {
      $section_count = 0;
      $sql = "SELECT $idcol, $column FROM {{$table}} WHERE $column LIKE ?";
      $params = ['%' . $garbled . '%'];
      $results = $DB->get_records_sql($sql, $params);
      foreach ($results as $row) {
        $link = make_link($table, $row->$idcol, $link_pattern, $CFG);
        echo "Found '$garbled' in $table.$column (id={$row->$idcol})";
        if ($link) {
          echo " [ <a href=\"$link\" target=\"_blank\">$link</a> ]";
        }
        echo "\n";
        echo "<br />";
        $count++;
        $section_count++;
      }
      if ($section_count > 0) {
        echo "<br />";
        echo "Found $section_count occurrences of '$garbled' in $table.$column\n";
        echo "<br />";
        echo "<br />";
      }
    }
  }
  echo "Total occurrences found: $count\n";
}

// --- REPLACE FUNCTION ---
function replace_mojibake($DB, $mojibake_replacements, $moodle_content_columns) {
    $total_replacements = 0;
    $pass = 1;
    do {
        $matches_before = 0;
        foreach ($moodle_content_columns as $colinfo) {
            list($table, $column, $idcol, $link_pattern) = $colinfo;
            foreach ($mojibake_replacements as $garbled => $intended) {
                $like = '%' . $garbled . '%';
                $countsql = "SELECT COUNT(*) FROM {{$table}} WHERE $column LIKE ?";
                $matches_before += $DB->get_field_sql($countsql, [$like]);
            }
        }

        echo "<p>Replacement pass $pass ...</p>";

        foreach ($moodle_content_columns as $colinfo) {
            list($table, $column, $idcol, $link_pattern) = $colinfo;
            foreach ($mojibake_replacements as $garbled => $intended) {
                $sql = "UPDATE {{$table}} SET $column = REPLACE($column, ?, ?) WHERE $column LIKE ?";
                $params = [$garbled, $intended, '%' . $garbled . '%'];
                $DB->execute($sql, $params);
            }
        }

        $matches_after = 0;
        foreach ($moodle_content_columns as $colinfo) {
            list($table, $column, $idcol, $link_pattern) = $colinfo;
            foreach ($mojibake_replacements as $garbled => $intended) {
                $like = '%' . $garbled . '%';
                $countsql = "SELECT COUNT(*) FROM {{$table}} WHERE $column LIKE ?";
                $matches_after += $DB->get_field_sql($countsql, [$like]);
            }
        }

        $replacements_this_pass = $matches_before - $matches_after;
        $total_replacements += $replacements_this_pass;
        $pass++;

    } while ($replacements_this_pass > 0);

    echo "<p>Total occurrences replaced: $total_replacements</p>\n";
}

// --- MAIN ---
$mode = $argv[1] ?? '';
if (empty($mode)) {
  $mode = isset($_REQUEST['mode']) ? $_REQUEST['mode'] : '';
}
if ($mode === 'find') {
  find_mojibake($DB, $mojibake_replacements, $moodle_content_columns, $CFG);
} elseif ($mode === 'replace') {
  replace_mojibake($DB, $mojibake_replacements, $moodle_content_columns);
} else {
  echo "<p>Usage: php /var/www/html/fix-mojibake.php [find|replace]</p>\n";
}

echo '<p><a href="' . $CFG->wwwroot . '/fix-mojibake.php?mode=find">FIND Mojibake</a></p>';
echo '<p><a href="' . $CFG->wwwroot . '/fix-mojibake.php?mode=replace">REPLACE Mojibake</a></p>';
