<?php
defined('MOODLE_INTERNAL') || die();

if ($ADMIN->fulltree) {
    $settings->add(new admin_setting_configtext('cachestore_redisfile/hostname', get_string('hostname', 'cachestore_redisfile'), get_string('hostname_desc', 'cachestore_redisfile'), 'localhost'));
    $settings->add(new admin_setting_configtext('cachestore_redisfile/port', get_string('port', 'cachestore_redisfile'), get_string('port_desc', 'cachestore_redisfile'), 6379));
    $settings->add(new admin_setting_configtext('cachestore_redisfile/prefix', get_string('prefix', 'cachestore_redisfile'), get_string('prefix_desc', 'cachestore_redisfile'), 'moodle_'));
}
