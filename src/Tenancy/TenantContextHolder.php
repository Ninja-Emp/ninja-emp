<?php

declare(strict_types=1);

namespace NinjaEMP\Tenancy;

use NinjaEMP\Db\TenantContext;
use RuntimeException;

/**
 * A request-scoped holder for the resolved TenantContext.
 *
 * The tenant is resolved by middleware (from the host or an explicit slug) and
 * stored here so that lazily-built services — notably the repository — can read
 * it without the container needing to know about the request. One holder per
 * request; never shared across requests.
 */
final class TenantContextHolder
{
    private ?TenantContext $context = null;

    public function set(TenantContext $context): void
    {
        $this->context = $context;
    }

    public function has(): bool
    {
        return $this->context !== null;
    }

    public function get(): TenantContext
    {
        if ($this->context === null) {
            throw new RuntimeException('No tenant context has been resolved for this request.');
        }

        return $this->context;
    }

    public function clear(): void
    {
        $this->context = null;
    }
}
