<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Value;

use NinjaEMP\Db\Sql\Identifier;
use NinjaEMP\Db\TenantContext;

/**
 * Immutable TenantContext value object. Validates the schema name up front so an
 * unsafe identifier can never reach SET LOCAL.
 */
final class Tenant implements TenantContext
{
    private function __construct(
        private readonly string $tenantId,
        private readonly ?string $actorId,
        private readonly string $schema,
    ) {
    }

    public static function of(string $tenantId, string $schema, ?string $actorId = null): self
    {
        // Fail fast on an unsafe schema name.
        Identifier::of($schema);

        return new self($tenantId, $actorId, $schema);
    }

    public function tenantId(): string
    {
        return $this->tenantId;
    }

    public function actorId(): ?string
    {
        return $this->actorId;
    }

    public function schema(): string
    {
        return $this->schema;
    }

    public function withActor(?string $actorId): self
    {
        return new self($this->tenantId, $actorId, $this->schema);
    }
}
