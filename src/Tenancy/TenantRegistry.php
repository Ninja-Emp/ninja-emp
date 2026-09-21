<?php

declare(strict_types=1);

namespace NinjaEMP\Tenancy;

/**
 * Resolves a request to a tenant (control plane, ADR-0008).
 *
 * The control plane lives in its own database; this interface is the seam so the
 * resolver can be backed by a real query or an in-memory map in tests.
 */
interface TenantRegistry
{
    /** Resolve by slug (e.g. "acme-mall"), or null when unknown. */
    public function findBySlug(string $slug): ?TenantRecord;

    /** Resolve by request host (e.g. "acme.ninjaemp.app"), or null. */
    public function findByHost(string $host): ?TenantRecord;
}
