<?php

declare(strict_types=1);

namespace NinjaEMP\Db;

/**
 * The thin, owned data-access contract every domain module depends on (ADR-0025).
 *
 * Not an ORM. SQL is written by hand and visible. The contract exists to make the
 * dangerous parts — money typing, tenant context, transactions, pooling —
 * impossible to get wrong by accident.
 */
interface Connection
{
    /**
     * Run a SELECT; returns rows as typed values.
     *
     * @param array<string, mixed> $params
     */
    public function select(string $sql, array $params = []): ResultSet;

    /**
     * Run a SELECT returning exactly one row (or throw).
     *
     * @param array<string, mixed> $params
     */
    public function selectOne(string $sql, array $params = []): Row;

    /**
     * Run an INSERT/UPDATE/DELETE; returns affected row count.
     *
     * @param array<string, mixed> $params
     */
    public function execute(string $sql, array $params = []): int;

    /**
     * Call a function returning a scalar (e.g. post_journal_entry).
     *
     * @param array<string, mixed> $params
     */
    public function scalar(string $sql, array $params = []): mixed;

    /**
     * Call a function returning a scalar and narrow it to a string (e.g. an id).
     *
     * @param array<string, mixed> $params
     */
    public function scalarString(string $sql, array $params = []): string;

    /**
     * Call a function returning a scalar and narrow it to an int (e.g. a count).
     *
     * @param array<string, mixed> $params
     */
    public function scalarInt(string $sql, array $params = []): int;

    /**
     * Run a closure inside a transaction; commits on return, rolls back on throw.
     * This is the ONLY way to run tenant-scoped work (SET LOCAL needs a tx).
     *
     * @template T
     *
     * @param callable(Connection): T $work
     *
     * @return T
     */
    public function transactional(callable $work): mixed;

    public function lastInsertId(): string;
}
