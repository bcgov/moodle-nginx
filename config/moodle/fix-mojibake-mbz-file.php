<?php
$backup_dir = '/tmp/courses/backups/';
$unzip_dir = '/tmp/courses/unzipped/';

echo "Processing .mbz files in $backup_dir\n";
if (!is_dir($backup_dir)) {
    echo "Backup directory does not exist: $backup_dir\n";
    exit(1);
}
if (!is_dir($unzip_dir)) {
    echo "Unzip directory does not exist: $unzip_dir\n";
    exit(1);
}

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
        echo "Failed to extract tar: " . $e->getMessage() . "\n";
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
      echo "Created $mbz_path\n";
      return true;
  } catch (Exception $e) {
      echo "Failed to create mbz: " . $e->getMessage() . "\n";
      return false;
  }
}

// Helper: Recursively process files for mojibake
function process_files($dir, $mojibake_replacements) {
  $rii = new RecursiveIteratorIterator(new RecursiveDirectoryIterator($dir));
  $total_replacement_count = 0;
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
          if ($fixed !== $content) {
              file_put_contents($file, $fixed);
              $total_replacement_count += $replacement_count;
              echo "Fixed {$replacement_count} mojibake characters in: {$file}\n";
          }
      }
  }

  if ($total_replacement_count > 0) {
      echo "Total mojibake characters fixed in $dir: $total_replacement_count\n";
  } else {
      echo "No mojibake characters found in directory $dir\n";
  }
}

// Main: Process all .mbz files in backup_dir
foreach (glob($backup_dir . '*.mbz') as $mbz) {
  $basename = basename($mbz, '.mbz');
  $extract_path = $unzip_dir . $basename . '/';
  if (!is_dir($extract_path)) mkdir($extract_path, 0777, true);

  echo "Unzipping $mbz to $extract_path\n";
  if (!extract_mbz($mbz, $extract_path)) {
      echo "Failed to unzip $mbz\n";
      continue;
  }

  // Check for nested zip (sometimes Moodle backups have a single zip inside)
  foreach (glob($extract_path . '*.zip') as $inner_zip) {
      echo "Unzipping nested $inner_zip...\n";
      extract_mbz($inner_zip, $extract_path);
      unlink($inner_zip); // Remove inner zip after extraction
  }

  // Process all files for mojibake
  process_files($extract_path, $mojibake_replacements);

  // Create new .mbz file
  $new_mbz = $backup_dir . 'fixed-' . $basename . '.mbz';
  if (file_exists($new_mbz)) unlink($new_mbz);
  create_mbz($extract_path, $new_mbz);

  // Clean up extracted files
  array_map('unlink', glob("$extract_path/*.*"));
  rmdir($extract_path);
  echo "Created fixed mbz: $new_mbz\n";
}

echo "Done.\n";
