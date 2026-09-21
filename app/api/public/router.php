<?php

declare(strict_types=1);

/**
 * Router for PHP's built-in server (php -S). Serves static files directly and
 * forwards everything else to the front controller.
 */
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
$file = __DIR__ . $path;

if ($path !== '/' && is_file($file)) {
    return false;
}

require __DIR__ . '/index.php';
