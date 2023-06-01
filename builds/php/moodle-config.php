<?php  // Moodle configuration file

// require_once('/vendor/autoload.php');

// $dotenv = Dotenv\Dotenv::createImmutable('/');
// $dotenv->load();

unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'DB_HOST';
$CFG->dbname    = 'DB_NAME';
$CFG->dbuser    = 'DB_USER';
$CFG->dbpass    = 'DB_PASSWORD';
$CFG->moodleappdir    = 'MOODLE_APP_DIR';
$CFG->prefix    = '';
$CFG->tool_generator_users_password = 'moodle-gen-PWd';

$CFG->dboptions =  array (
  'dbpersist' => 0,
  'dbport' => 'DB_PORT',
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

// $CFG->dboptions['readonly'] = array (
//   'instance' => [
//       'dbhost' => 'DB_HOST_2',
//       'dbport' => 'DB_PORT'
//     ],
//   'latency' => '2'
// );

$protocol = (isset($_SERVER['HTTP_X_FORWARDED_PROTO']) && $_SERVER['HTTP_X_FORWARDED_PROTO'] === 'https') ? 'https://' : 'http://';
$moodle_dir = stripos($_SERVER['REQUEST_URI'], '/moodle') === 0 ? '/moodle' : ''; // for local dev in /moodle folder
$requested_site_url = $protocol.$_SERVER['HTTP_HOST'].$moodle_dir;

$CFG->wwwroot   = $requested_site_url;
$CFG->dataroot  = '/var/moodledata';
$CFG->admin     = 'admin';
// $CFG->alternateloginurl  = (isset($_ENV['ALTERNATE_LOGIN_URL'])) ? $_ENV['ALTERNATE_LOGIN_URL'] : '';

$CFG->directorypermissions = 0777;

$CFG->sslproxy = ( stristr($CFG->wwwroot, "gov.bc.ca") || stristr($CFG->wwwroot, "apps-crc.testing") ) ? true : false; // Only use in OCP environments

$CFG->getremoteaddrconf = 0;

if (isset($_REQUEST['debug'])) {
  echo '<pre>',print_r($_SERVER),'</pre>';
  echo '<pre>',print_r($CFG),'</pre>';
}

require_once(__DIR__ . '/lib/setup.php');

// There is no php closing tag in this file,
// it is intentional because it prevents trailing whitespace problems!
