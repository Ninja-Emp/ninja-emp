<?php

declare(strict_types=1);

use NinjaEMP\Db\Sql\Value;
/**
 * Router script for PHP's built-in dev server.
 *
 * Usage: php -S localhost:8090 -t public public/router.php
 *
 * Serves real static files directly; forwards everything else to the front
 * controller. (Production uses a real web server with a rewrite rule.)
 */
$path = parse_url(Value::str($_SERVER['REQUEST_URI'] ?? '/'), PHP_URL_PATH);
$path = $path === false || $path === null ? '/' : $path;
$file = __DIR__ . $path;

if ($path !== '/' && is_file($file)) {
    return false; // let the built-in server serve the static asset
}

require __DIR__ . '/index.php';
