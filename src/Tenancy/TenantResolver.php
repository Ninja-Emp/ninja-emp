<?php

declare(strict_types=1);

namespace NinjaEMP\Tenancy;

use NinjaEMP\Db\Value\Tenant;

/**
 * Resolves an incoming request to a TenantContext (schema-per-tenant, ADR-0008).
 *
 * Resolution order:
 *   1. an explicit slug (e.g. a path prefix or a session value),
 *   2. the request host (subdomain routing).
 *
 * The resolved schema is validated by TenantRecord, so an unsafe identifier can
 * never reach SET LOCAL.
 */
final class TenantResolver
{
    public function __construct(private readonly TenantRegistry $registry)
    {
    }

    public function resolve(?string $slug, ?string $host, ?string $actorId = null): ?Tenant
    {
        $record = null;

        if ($slug !== null && $slug !== '') {
            $record = $this->registry->findBySlug($slug);
        }

        if ($record === null && $host !== null && $host !== '') {
            $record = $this->registry->findByHost($this->stripPort($host));
        }

        if ($record === null || !$record->isActive()) {
            return null;
        }

        return Tenant::of($record->id, $record->schemaName, $actorId);
    }

    private function stripPort(string $host): string
    {
        $colon = strrpos($host, ':');

        return $colon === false ? $host : substr($host, 0, $colon);
    }
}
