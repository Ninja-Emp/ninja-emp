<?php

declare(strict_types=1);

namespace NinjaEMP\Tenancy;

use NinjaEMP\Db\Sql\Identifier;

/**
 * A row from control.tenant. Immutable.
 */
final class TenantRecord
{
    public function __construct(
        public readonly string $id,
        public readonly string $slug,
        public readonly string $schemaName,
        public readonly string $legalName,
        public readonly string $status = 'active',
        public readonly string $poolGroup = 'default',
    ) {
        // Fail fast: an unsafe schema name must never reach SET LOCAL.
        Identifier::of($this->schemaName);
    }

    public function isActive(): bool
    {
        return $this->status === 'active';
    }
}
