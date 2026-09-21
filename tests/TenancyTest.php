<?php

declare(strict_types=1);

use NinjaEMP\Tenancy\InMemoryTenantRegistry;
use NinjaEMP\Tenancy\TenantRecord;
use NinjaEMP\Tenancy\TenantResolver;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Tenancy');

    $registry = new InMemoryTenantRegistry();
    $registry->add(
        new TenantRecord('11111111-1111-7111-8111-111111111111', 'acme-mall', 'tenant_acme', 'Acme Mall LLC'),
        'acme.ninjaemp.app',
    );
    $registry->add(
        new TenantRecord('22222222-2222-7222-8222-222222222222', 'beta-mall', 'tenant_beta', 'Beta Mall', 'suspended'),
        'beta.ninjaemp.app',
    );

    $resolver = new TenantResolver($registry);

    // Resolve by slug.
    $tenant = $resolver->resolve('acme-mall', null);
    $t->assertSame('tenant_acme', $tenant?->schema(), 'resolves schema by slug');
    $t->assertSame('11111111-1111-7111-8111-111111111111', $tenant?->tenantId(), 'resolves tenant id');

    // Resolve by host (with port stripped).
    $tenant = $resolver->resolve(null, 'acme.ninjaemp.app:8091');
    $t->assertSame('tenant_acme', $tenant?->schema(), 'resolves schema by host, port stripped');

    // Slug wins over host.
    $tenant = $resolver->resolve('acme-mall', 'beta.ninjaemp.app');
    $t->assertSame('tenant_acme', $tenant?->schema(), 'slug takes precedence');

    // Suspended tenant is not resolvable.
    $t->assertSame(null, $resolver->resolve('beta-mall', null), 'suspended tenant rejected');

    // Unknown tenant.
    $t->assertSame(null, $resolver->resolve('nope', null), 'unknown slug returns null');
    $t->assertSame(null, $resolver->resolve(null, 'nope.example.com'), 'unknown host returns null');

    // Actor id is threaded through.
    $tenant = $resolver->resolve('acme-mall', null, 'actor-9');
    $t->assertSame('actor-9', $tenant?->actorId(), 'actor id threaded through');

    // Unsafe schema name is rejected at construction.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => new TenantRecord('id', 'bad', 'tenant;drop', 'Bad'),
        'unsafe schema name rejected',
    );
};
