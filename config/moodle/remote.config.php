<?php  // Moodle configuration file

@error_reporting(E_ALL | E_STRICT);
@ini_set('display_errors', 0);

unset($CFG);
global $CFG;
$CFG = new stdClass();

// Do not do this unless you understand all the consequences.
$CFG->disablelogintoken = true;

$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = $_SERVER['DB_HOST'];
$CFG->dbname    = $_SERVER['DB_NAME'];
$CFG->dbuser    = $_SERVER['DB_USER'];
$CFG->dbpass    = $_SERVER['DB_PASSWORD'];
$CFG->moodleappdir    = '/var/www/html';
$CFG->prefix    = '';
$CFG->tool_generator_users_password = 'moodle-gen-PWd';

// $CFG->debug = (E_ALL | E_STRICT);
$CFG->debugdisplay = 0;
$CFG->debugsessionlock = 10; // Time in seconds

$CFG->langstringcache = 1;
$CFG->cachejs = 1;
$CFG->themedesignermode = 0;
$CFG->enablecssoptimiser = 1;

// $CFG->session_redis_host = 'redis';
$CFG->session_redis_host = $_SERVER['REDIS_HOST'];
// $CFG->session_redis_auth = $_SERVER['REDIS_PASSWORD'];
$CFG->session_handler_class = '\core\session\redis';
// $CFG->session_handler_class = '\core\session\file';
$CFG->session_redis_port = 6379; // Optional if TCP. For socket use -1
$CFG->session_redis_database = 0; // Optional, default is db 0.
$CFG->session_redis_acquire_lock_timeout = 120;
$CFG->session_redis_lock_expire = 7200;
$CFG->session_redis_serializer_use_igbinary = true;
// $CFG->session_redis_compressor = 'gzip';

// filecache should be on LOCAL fast storage
$CFG->filecache = '/mnt/ramdisk/filecache';
// localrequestdir should be on LOCAL fast storage
$CFG->localrequestdir = '/mnt/ramdisk/requests';
$CFG->backuptempdir = '/var/www/moodledata/temp/backup';
// cachedir should be on SHARED storage
$CFG->cachedir = '/var/shared/cache';
// tempdir should be on SHARED storage
$CFG->tempdir = '/var/shared/temp';

$CFG->dboptions =  array (
    'dbpersist' => 0,
    'dbport' => '3306',
    'dbsocket' => '',
    'dbcollation' => 'utf8mb4_unicode_ci',
    'logslow'  => 5,
    'logerrors'  => true,
);

$CFG->dataroot  = '/var/www/moodledata';
$CFG->admin     = 'admin';
// $CFG->alternateloginurl  = (isset($_SERVER['ALTERNATE_LOGIN_URL'])) ? $_SERVER['ALTERNATE_LOGIN_URL'] : '';

$CFG->xsendfile = 'X-Accel-Redirect';
$CFG->xsendfilealiases = array(
    '/dataroot/' => $CFG->dataroot,
    '/filedir/' => $CFG->dataroot.'/filedir',
    '/localcachedir/' => $CFG->filecache,
    '/tempdir/' => $CFG->tempdir,
    '/cachedir/' => $CFG->cachedir,
);

if (php_sapi_name() == "cli") {
    $CFG->wwwroot = '/var/www/html';
} else {
    $protocol = 'https://';
    $moodle_dir = stripos($_SERVER['REQUEST_URI'], '/moodle') === 0 ? '/moodle' : ''; // for local dev in /moodle folder
    $CFG->wwwroot = $protocol.$_SERVER['HTTP_HOST'].$moodle_dir;
}

$CFG->directorypermissions = 02777;

$CFG->sslproxy = ( stristr($CFG->wwwroot, "gov.bc.ca") || stristr($CFG->wwwroot, "apps-crc.testing") ) ? true : false; // Only use in OCP environments

$CFG->getremoteaddrconf = 0;

function loadTestCacheDisk($size_in_mb = 1, $num_files = 1) {
  $base_dir = '/mnt/ramdisk/filecache/';
  $data = str_repeat('A', 1024 * 1024 * $size_in_mb); // Adjust size based on parameter

  echo 'Testing Disk Cache for '.$base_dir.'... <br>';

  // Check if the directory exists
  if (!is_dir($base_dir)) {
    $_ENV['debug_load_test_cache_disk_msg'] .= "Directory does not exist: " . $base_dir . "\n";
    $_ENV['debug_load_test_cache_disk_msg'] .= "Creating directory: " . $base_dir . "\n";
    if (!mkdir($base_dir, 0777, true)) {
      $_ENV['debug_load_test_cache_disk_msg'] .= "Failed to create directory: " . $base_dir . "\n";
      return;
    }
  }

  // Check if the directory is writable
  if (!is_writable($base_dir)) {
    $_ENV['debug_load_test_cache_disk_msg'] .= "Directory is not writable: " . $base_dir . "\n";
    return;
  }

  $testfilesArray = array();

  for ($i = 0; $i < $num_files; $i++) {
    $test_file = $base_dir . uniqid('test_file_', true) . '.txt';
    $testfilesArray[] = $test_file;
    $start_time = microtime(true);
    $result = @file_put_contents($test_file, $data);
    $end_time = microtime(true);

    if ($result === false) {
      $_ENV['debug_load_test_cache_disk_msg'] .= "Failed to write to file: " . $test_file . "\n";
      $_ENV['debug_load_test_cache_disk_msg'] .= "Error: " . error_get_last()['message'] . "\n";
    } else {
      $write_time = $end_time - $start_time;
      $_ENV['debug_load_test_cache_disk_msg'] .= "Write time for {$size_in_mb}MB file {$i}: {$write_time} seconds\n";
    }
  }

  foreach ($testfilesArray as $test_file) {
    if (file_exists($test_file)) {
      if (unlink($test_file)) {
        $_ENV['debug_load_test_cache_disk_msg'] .= "Deleted file: " . $test_file . "\n";
      } else {
        $_ENV['debug_load_test_cache_disk_msg'] .= "Failed to delete file: " . $test_file . "\n";
      }
    }
  }
}

if (isset($_REQUEST['TEST_CACHE_DISK'])) {
  $size_in_mb = isset($_REQUEST['SIZE_IN_MB']) ? intval($_REQUEST['SIZE_IN_MB']) : 1;
  $num_files = isset($_REQUEST['NUM_FILES']) ? intval($_REQUEST['NUM_FILES']) : 1;
  loadTestCacheDisk($size_in_mb, $num_files);
}

require_once($CFG->moodleappdir . '/vendor/autoload.php');
require_once(__DIR__ . '/lib/setup.php');

if (@$_ENV['debug_load_test_cache_disk_msg'] != '') {
    echo $_ENV['debug_load_test_cache_disk_msg'];
}

if (isset($_REQUEST['debug'])) {
    echo '<p><strong>$_SERVER</strong></p>',
      '<pre>', print_r($_SERVER), '</pre>',
      '<p><strong>$CFG</strong></p>',
      '<pre>', print_r($CFG), '</pre>';
}

// There is no php closing tag in this file,
// it is intentional because it prevents trailing whitespace problems!
