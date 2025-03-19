<?php
defined('MOODLE_INTERNAL') || die();

class cachestore_redisfile extends cachestore {
    protected $redis;

    public function __construct($name, $configuration) {
        parent::__construct($name, $configuration);
        $this->redis = new Redis();
        $this->redis->connect($configuration['hostname'], $configuration['port']);
        $this->redis->setOption(Redis::OPT_PREFIX, $configuration['prefix']);
    }

    public function get($key) {
        return $this->redis->get($key);
    }

    public function set($key, $data) {
        return $this->redis->set($key, $data);
    }

    public function delete($key) {
        return $this->redis->del($key);
    }

    public function purge() {
        return $this->redis->flushDB();
    }
}
