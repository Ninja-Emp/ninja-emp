<?php

declare(strict_types=1);

/**
 * PHPUnit bootstrap.
 *
 * Loads the Composer autoloader and then the local `.env` (if present) so the
 * functional DBAL tests can reach a real PostgreSQL. Real environment variables
 * always win over the file (see NinjaEMP\Support\Env).
 */

require dirname(__DIR__) . '/vendor/autoload.php';

NinjaEMP\Support\Env::load(dirname(__DIR__) . '/.env');
