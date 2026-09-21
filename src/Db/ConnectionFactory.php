<?php

declare(strict_types=1);

namespace NinjaEMP\Db;

use PDO;

/**
 * Builds PDO connections configured for the DBAL contract (ADR-0025 §4).
 *
 * Defaults are chosen for PgBouncer transaction mode:
 *  - ATTR_EMULATE_PREPARES = true (client-side prepares are pooling-safe),
 *  - ATTR_ERRMODE = EXCEPTION (so SQLSTATE reaches the ErrorMapper),
 *  - ATTR_STRINGIFY_FETCHES = false (we want native types where PDO provides them),
 *  - persistent connections off (pooling is PgBouncer's job, not PDO's).
 */
final class ConnectionFactory
{
    public function __construct(
        private readonly string $dsn,
        private readonly string $user,
        private readonly string $password,
        private readonly bool $emulatePrepares = true,
    ) {
    }

    public function create(TenantContext $context): PdoConnection
    {
        $pdo = new PDO($this->dsn, $this->user, $this->password, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
            PDO::ATTR_EMULATE_PREPARES => $this->emulatePrepares,
            PDO::ATTR_STRINGIFY_FETCHES => false,
            PDO::ATTR_PERSISTENT => false,
        ]);

        return new PdoConnection($pdo, $context);
    }
}
