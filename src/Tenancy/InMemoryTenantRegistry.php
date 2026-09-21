<?php

declare(strict_types=1);

namespace NinjaEMP\Tenancy;

/**
 * In-memory tenant registry for tests and local dev. Production uses a
 * control-plane-backed implementation.
 */
final class InMemoryTenantRegistry implements TenantRegistry
{
    /** @var array<string, TenantRecord> keyed by slug */
    private array $bySlug = [];

    /** @var array<string, TenantRecord> keyed by host */
    private array $byHost = [];

    public function add(TenantRecord $tenant, ?string $host = null): void
    {
        $this->bySlug[$tenant->slug] = $tenant;

        if ($host !== null) {
            $this->byHost[strtolower($host)] = $tenant;
        }
    }

    public function findBySlug(string $slug): ?TenantRecord
    {
        return $this->bySlug[$slug] ?? null;
    }

    public function findByHost(string $host): ?TenantRecord
    {
        return $this->byHost[strtolower($host)] ?? null;
    }
}
