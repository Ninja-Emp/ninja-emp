<?php

declare(strict_types=1);

namespace NinjaEMP\Db;

/**
 * The tenant/actor identity a connection operates as. Set per transaction via
 * SET LOCAL so it can never leak across pooled connections (ADR-0010).
 */
interface TenantContext
{
    /** Tenant uuid. */
    public function tenantId(): string;

    /** Acting user/service uuid, or null for system work. */
    public function actorId(): ?string;

    /** Tenant schema, e.g. "tenant_acme". Validated against ^[a-z_][a-z0-9_]*$. */
    public function schema(): string;
}
