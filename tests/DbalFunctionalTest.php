<?php

declare(strict_types=1);

use NinjaEMP\Db\ConnectionFactory;
use NinjaEMP\Db\Value\Tenant;
use NinjaEMP\Tests\TestHarness;

/**
 * Functional DBAL tests against a real PostgreSQL. They auto-skip when no
 * database is reachable, so the unit suite stays green in any environment.
 *
 * To run: provision the DB (db/provision.sh), then
 *   NINJA_EMP_DSN="pgsql:host=127.0.0.1;dbname=ninja_emp" \
 *   NINJA_EMP_DB_USER=ninja_app NINJA_EMP_DB_PASSWORD=... \
 *   NINJA_EMP_TENANT_ID=11111111-1111-7111-8111-111111111111 \
 *   NINJA_EMP_SCHEMA=tenant_demo php tests/run.php
 *
 * In practice these come from `.env` (loaded by tests/bootstrap.php and
 * tests/run.php), so a provisioned checkout runs them with no extra setup.
 */
return static function (TestHarness $t): void {
    $t->suite('DBAL (functional)');

    $dsn = getenv('NINJA_EMP_DSN');

    if ($dsn === false || $dsn === '') {
        echo "  · DBAL functional tests skipped (set NINJA_EMP_DSN to run)\n";

        return;
    }

    $factory = new ConnectionFactory(
        $dsn,
        (string) getenv('NINJA_EMP_DB_USER'),
        (string) getenv('NINJA_EMP_DB_PASSWORD'),
    );

    $tenant = Tenant::of(
        (string) getenv('NINJA_EMP_TENANT_ID'),
        (string) (getenv('NINJA_EMP_SCHEMA') ?: 'tenant_demo'),
    );

    $db = $factory->create($tenant);

    // 1. Tenant context is applied inside a transaction.
    $schema = $db->transactional(fn () => $db->scalar('SELECT current_schema()'));
    $t->assertSame($tenant->schema(), (string) $schema, 'search_path resolves to tenant schema');

    // 2. app.tenant_id is visible to the kernel helper.
    $tid = $db->transactional(fn () => $db->scalar('SELECT kernel.current_tenant()::text'));
    $t->assertSame($tenant->tenantId(), (string) $tid, 'app.tenant_id set for RLS');

    // 3. A bare query outside a transaction is a programming error.
    $t->assertThrows(
        NinjaEMP\Db\Exception\TransactionRequiredException::class,
        fn () => $db->select('SELECT 1'),
        'query outside transaction throws',
    );

    // 4. Rollback on throw leaves no trace.
    $before = (int) $db->transactional(fn () => $db->scalar('SELECT count(*) FROM account'));

    try {
        $db->transactional(function () use ($db): void {
            $db->execute("INSERT INTO account (code, name, account_type_code) VALUES ('ZZZ', 'Temp', 'asset')");

            throw new RuntimeException('boom');
        });
    } catch (RuntimeException) {
        // expected
    }
    $after = (int) $db->transactional(fn () => $db->scalar('SELECT count(*) FROM account'));
    $t->assertSame($before, $after, 'rollback discards the insert');

    // 5. Idempotent posting: same key returns the same entry id.
    $post = fn (): string => (string) $db->transactional(fn () => $db->scalar(
        'SELECT post_journal_entry(:date, :memo, :source, :ref, :key, :lines)',
        [
            'date' => '2026-01-02',
            'memo' => 'DBAL functional test',
            'source' => 'test',
            'ref' => 't-1',
            'key' => 'dbal-func-key-1',
            'lines' => json_encode([
                ['account_id' => $db->transactional(fn () => $db->scalar('SELECT posting_account(:r)', ['r' => 'undeposited_funds'])), 'debit' => '10.0000', 'credit' => '0.0000', 'currency' => 'USD'],
                ['account_id' => $db->transactional(fn () => $db->scalar('SELECT posting_account(:r)', ['r' => 'sales_revenue'])), 'debit' => '0.0000', 'credit' => '10.0000', 'currency' => 'USD'],
            ], JSON_THROW_ON_ERROR),
        ],
    ));

    $first = $post();
    $second = $post();
    $t->assertSame($first, $second, 'idempotency key returns the same entry id');
};
