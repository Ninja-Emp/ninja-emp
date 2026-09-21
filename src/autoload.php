<?php

declare(strict_types=1);

/**
 * Minimal PSR-4 autoloader (no Composer, per HANDOFF.md §2).
 *
 * Maps:
 *   NinjaEMP\  -> src/
 *   Psr\Log\   -> src/Psr/Log/
 */
spl_autoload_register(static function (string $class): void {
    $prefixes = [
        'NinjaEMP\\' => __DIR__ . '/',
        'Psr\\Log\\' => __DIR__ . '/Psr/Log/',
    ];

    foreach ($prefixes as $prefix => $baseDir) {
        if (!str_starts_with($class, $prefix)) {
            continue;
        }

        $relative = substr($class, strlen($prefix));
        $file = $baseDir . str_replace('\\', '/', $relative) . '.php';

        if (is_file($file)) {
            require $file;
        }

        return;
    }
});
