<?php

declare(strict_types=1);

/**
 * Ninja EMP — bootstrap autoloader.
 *
 * The application is dependency-free by design: it depends on the PSR
 * *interfaces* (PSR-3/4/7/11/12/15), not on any concrete package. That means it
 * can run with or without Composer.
 *
 *   1. If Composer has been installed (`vendor/autoload.php` exists), we use it.
 *      This is the normal path for development and CI.
 *   2. Otherwise we register a tiny PSR-4 autoloader for the project's own
 *      namespaces and load minimal PSR interface stubs, so the app boots
 *      unchanged on a machine that has only PHP — no Composer, no `make`.
 *
 * Every entry point (both apps' `public/index.php` and `public/router.php`)
 * requires this file instead of `vendor/autoload.php` directly.
 *
 * The body is wrapped in a closure so its local variables can never leak into
 * (and clobber) the scope of the script that requires it.
 */

(static function (): void {
    $root = dirname(__DIR__);

    $composer = $root . '/vendor/autoload.php';

    if (is_file($composer)) {
        require $composer;

        return;
    }

    // -----------------------------------------------------------------------
    // Zero-dependency fallback: PSR-4 for the project's own namespaces.
    // -----------------------------------------------------------------------
    spl_autoload_register(static function (string $class) use ($root): void {
        // Order matters: the two app namespaces are checked before the shared
        // one. Matching is case-insensitive because PHP class names are.
        $map = [
            'NinjaEmp\\TenantUi\\' => '/apps/tenant-ui/src/',
            'NinjaEmp\\Api\\'      => '/apps/api/src/',
            'NinjaEMP\\'           => '/src/',
        ];

        foreach ($map as $prefix => $dir) {
            if (strncasecmp($class, $prefix, strlen($prefix)) !== 0) {
                continue;
            }

            $relative = substr($class, strlen($prefix));
            $file = $root . $dir . str_replace('\\', '/', $relative) . '.php';

            if (is_file($file)) {
                require $file;
            }

            return;
        }
    });

    // Minimal PSR interfaces so the API layer boots without Composer.
    require __DIR__ . '/psr-stubs.php';
})();
