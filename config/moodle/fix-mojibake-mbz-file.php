<?php
ini_set('memory_limit', '2048M');

$_ENV['debug'] = false;

$backup_dir = '/tmp/courses/backups/';
$_ENV['unzip_dir'] = '/tmp/courses/unzipped/';
$fixed_dir = '/tmp/courses/fixed/';
$total_replacements = 0;
$total_files = 0;
$logfile = '/tmp/courses/fix-mojibake-mbz.log';

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

uksort($mojibake_replacements, function($a, $b) {
    return strlen($b) <=> strlen($a);
});

function logmsg($msg, $force = false) {
    global $logfile;
    if ($_ENV['debug'] || $force) echo "$msg";
    if (substr($msg, -1) !== "\n") $msg .= "\n";
    file_put_contents($logfile, $msg, FILE_APPEND);
}

// Helper: Unzip a file to a directory
function extract_mbz($mbz_path, $dest_dir) {
    // Step 1: Extract .gz to .tar
    $tar_path = $mbz_path . '.tar';
    $gz = gzopen($mbz_path, 'rb');
    $tar = fopen($tar_path, 'wb');
    if (!$gz || !$tar) return false;
    while (!gzeof($gz)) {
        fwrite($tar, gzread($gz, 4096));
    }
    fclose($tar);
    gzclose($gz);

    // Step 2: Extract .tar
    try {
        $phar = new PharData($tar_path);
        $phar->extractTo($dest_dir, null, true);
        unlink($tar_path); // Clean up
        return true;
    } catch (Exception $e) {
        logmsg("Failed to extract tar: " . $e->getMessage() . "\n");
        return false;
    }
}

function create_mbz($source_dir, $mbz_path) {
  $tar_path = $mbz_path . '.tar';
  // Create tar archive
  try {
      if (file_exists($tar_path)) unlink($tar_path);
      $phar = new PharData($tar_path);
      $phar->buildFromDirectory($source_dir);
      // Gzip the tar
      $phar->compress(Phar::GZ);
      // Move to final .mbz name
      rename($tar_path . '.gz', $mbz_path);
      unlink($tar_path);
      // logmsg("Created $mbz_path\n");
      return true;
  } catch (Exception $e) {
      logmsg("Failed to create mbz: " . $e->getMessage() . "\n");
      return false;
  }
}

// Helper: Recursively process files for mojibake
function process_files($dir, $mojibake_replacements) {
  $rii = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir));
  $total_replacement_count = 0;
  $course_name = str_replace($_ENV['unzip_dir'], "", $dir);

  foreach ($rii as $file) {
      if ($file->isDir()) continue;
      $ext = strtolower(pathinfo($file, PATHINFO_EXTENSION));
      // Only process text-based files
      if (in_array($ext, ['xml', 'txt', 'html', 'htm', 'json', 'md'])) {
          $content = file_get_contents($file);
          $replacement_count = 0;
          foreach ($mojibake_replacements as $garbled => $intended) {
              $replacement_count += substr_count($content, $garbled);
          }
          $fixed = strtr($content, $mojibake_replacements);

          // logmsg("DEBUG: replacement_count=$replacement_count, fixed_changed=" . ($fixed !== $content ? 'yes' : 'no') . " for $file\n");

          if ($fixed !== $content) {
              if (file_put_contents($file, $fixed) === false) {
                  logmsg("Failed to write to file: $file\n");
              } else {
                  $file = str_replace($_ENV['unzip_dir'], "", $file);
                  $file = str_replace($course_name, "", $file);
                  $total_replacement_count += $replacement_count;
                  logmsg("Replaced {$replacement_count} in: {$file}\n");
              }
          }
      }
  }

  if ($total_replacement_count > 0) {
      logmsg("Total: $total_replacement_count replacements in: $course_name\n", true);
  } else {
      logmsg("No replacements found in: $dir\n");
  }

  return $total_replacement_count;
}

// Recursively delete a directory and all its contents
function rrmdir($dir) {
    if (!is_dir($dir)) return;
    $objects = scandir($dir);
    foreach ($objects as $object) {
        if ($object == "." || $object == "..") continue;
        $path = $dir . DIRECTORY_SEPARATOR . $object;
        if (is_dir($path)) {
            rrmdir($path);
        } else {
            unlink($path);
        }
    }
    rmdir($dir);
}

// Main: Process all .mbz files in backup_dir

logmsg("Processing .mbz files in $backup_dir\n", true);

if (!is_dir($backup_dir)) {
    logmsg("Backup directory does not exist: $backup_dir\n");
    exit(1);
}
if (!is_dir($_ENV['unzip_dir'])) {
    logmsg("Unzip directory does not exist: " . $_ENV['unzip_dir'] . "\n");
    exit(1);
}

foreach (glob($backup_dir . '*.mbz') as $mbz) {
  $total_files++;
  $basename = basename($mbz, '.mbz');
  $extract_path = $_ENV['unzip_dir'] . $basename . '/';
  if (!is_dir($extract_path)) mkdir($extract_path, 0777, true);

  // logmsg("\nUnzipping $mbz to $extract_path\n");
  if (!extract_mbz($mbz, $extract_path)) {
      logmsg("Failed to unzip $mbz\n");
      continue;
  }

  // Check for nested zip (sometimes Moodle backups have a single zip inside)
  foreach (glob($extract_path . '*.zip') as $inner_zip) {
      // logmsg("Unzipping nested $inner_zip...\n");
      extract_mbz($inner_zip, $extract_path);
      unlink($inner_zip); // Remove inner zip after extraction
  }

  // Process all files for mojibake
  logmsg("\nProcessing files in $extract_path\n");
  $replacements_in_this_file = process_files($extract_path, $mojibake_replacements);
  $total_replacements += $replacements_in_this_file;

  // Create new .mbz file
  if (replacements_in_this_file > 0) {
      $new_mbz = $fixed_dir . 'fixed-' . $basename . '.mbz';
  } else {
      $new_mbz = $fixed_dir . $basename . '.mbz';
  }
  if (file_exists($new_mbz)) unlink($new_mbz);
  create_mbz($extract_path, $new_mbz);

  // Clean up extracted files
  rrmdir($extract_path);
  // logmsg("Created fixed mbz: $new_mbz\n\n");
}

logmsg("Done.\n", true);
logmsg("Total replacements: $total_replacements in $total_files files\n", true);
logmsg("All fixed .mbz files are in $fixed_dir\n", true);
logmsg("Logged to: $logfile\n", true);
