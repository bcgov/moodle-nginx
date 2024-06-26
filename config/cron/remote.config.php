<?php  // Moodle configuration file
unset($CFG);
global $CFG;
$CFG = new stdClass();

$CFG->dbtype    = 'mariadb';
$CFG->dblibrary = 'native';
$CFG->dbhost    = 'db';
$CFG->dbname    = $_SERVER['DB_NAME'];
$CFG->dbuser    = $_SERVER['DB_USER'];
$CFG->dbpass    = $_SERVER['DB_PASSWORD'];
$CFG->moodleappdir    = '/var/www/html';
$CFG->prefix    = '';
$CFG->tool_generator_users_password = 'moodle-gen-PWd';

// $CFG->session_redis_host = 'redis-redis-cluster';
// $CFG->session_handler_class = '\core\session\redis';
// $CFG->session_redis_port = 6379; // Optional if TCP. For socket use -1
// $CFG->session_redis_database = 0; // Optional, default is db 0.
// $CFG->session_redis_acquire_lock_timeout = 120;
// $CFG->session_redis_lock_expire = 7200;
// $CFG->session_redis_serializer_use_igbinary = true;

$CFG->dboptions =  array (
  'dbpersist' => 0,
  'dbport' => '3306',
  'dbsocket' => '',
  'dbcollation' => 'utf8mb4_unicode_ci',
);

$CFG->wwwroot = '/var/www/html';
$CFG->dataroot  = '/var/www/moodledata';
$CFG->admin     = 'admin';
// $CFG->alternateloginurl  = (isset($_SERVER['ALTERNATE_LOGIN_URL'])) ? $_SERVER['ALTERNATE_LOGIN_URL'] : '';

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