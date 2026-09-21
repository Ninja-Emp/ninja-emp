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
    /** Run a SELECT; returns rows as typed values. */
    public function select(string $sql, array $params = []): ResultSet;

    /** Run a SELECT returning exactly one row (or throw). */
    public function selectOne(string $sql, array $params = []): Row;

    /** Run an INSERT/UPDATE/DELETE; returns affected row count. */
    public function execute(string $sql, array $params = []): int;

    /** Call a function returning a scalar (e.g. post_journal_entry). */
    public function scalar(string $sql, array $params = []): mixed;

    /**
     * Run a closure inside a transaction; commits on return, rolls back on throw.
     * This is the ONLY way to run tenant-scoped work (SET LOCAL needs a tx).
     */
    public function transactional(callable $work): mixed;

    public function lastInsertId(): string;
}
