<?php

declare(strict_types=1);

use NinjaEMP\Db\Sql\Value;

/**
 * Router for PHP's built-in server (php -S). Serves static files directly and
 * forwards everything else to the front controller.
 */
require dirname(__DIR__, 3) . '/vendor/autoload.php';

$path = parse_url(Value::str($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$path = $path === false || $path === null ? '/' : $path;
$file = __DIR__ . $path;

if ($path !== '/' && is_file($file)) {
    return false;
}

require __DIR__ . '/index.php';
