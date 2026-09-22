<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\Support;

use NinjaEMP\Db\Connection;
use NinjaEMP\Db\ResultSet;
use NinjaEMP\Db\Row;
use NinjaEMP\Db\Sql\Value;
use RuntimeException;

/**
 * An in-memory Connection test double.
 *
 * It lets the repository layer be exercised without a live PostgreSQL: register
 * a handler against a SQL fragment, and the fake returns whatever that handler
 * produces. Every call is recorded so tests can assert on the SQL that was
 * issued and the parameters that were bound.
 *
 * This is deliberately simple — it is a stub, not a SQL engine. It exists to
 * prove the repository issues the right statements and maps the results
 * correctly, which is the part we can verify without a database.
 */
final class FakeConnection implements Connection
{
    /** @var list<array{needle:string, handler:callable}> */
    private array $handlers = [];

    /** @var list<array{sql:string, params:array<string,mixed>}> */
    public array $calls = [];

    /** @var list<array{sql:string, params:array<string,mixed>}> */
    public array $executes = [];

    public int $transactionCount = 0;

    public function __construct(private string $lastInsertId = '00000000-0000-0000-0000-000000000000')
    {
    }

    /**
     * Register a handler for any SQL containing $needle. The handler receives
     * ($sql, $params) and may return:
     *   - a list of associative rows (for select/selectOne),
     *   - a scalar (for scalar),
     *   - null (empty).
     */
    public function on(string $needle, callable $handler): self
    {
        $this->handlers[] = ['needle' => $needle, 'handler' => $handler];

        return $this;
    }

    public function select(string $sql, array $params = []): ResultSet
    {
        $this->calls[] = ['sql' => $sql, 'params' => $params];
        $result = $this->dispatch($sql, $params);

        if ($result === null) {
            return new ResultSet([]);
        }

        if (!\is_array($result)) {
            return new ResultSet([new Row(['value' => $result])]);
        }

        $rows = [];

        foreach ($result as $row) {
            $rows[] = new Row(\is_array($row) ? $row : ['value' => $row]);
        }

        return new ResultSet($rows);
    }

    public function selectOne(string $sql, array $params = []): Row
    {
        $set = $this->select($sql, $params);

        if ($set->isEmpty()) {
            throw new RuntimeException('selectOne() expected exactly one row, got none.');
        }

        return $set->first();
    }

    public function execute(string $sql, array $params = []): int
    {
        $this->calls[] = ['sql' => $sql, 'params' => $params];
        $this->executes[] = ['sql' => $sql, 'params' => $params];

        return 1;
    }

    public function scalar(string $sql, array $params = []): mixed
    {
        $this->calls[] = ['sql' => $sql, 'params' => $params];
        $result = $this->dispatch($sql, $params);

        if ($result === null) {
            return null;
        }

        if (\is_array($result)) {
            $first = $result[0] ?? null;

            if ($first === null) {
                return null;
            }

            return \is_array($first) ? reset($first) : $first;
        }

        return $result;
    }

    public function scalarString(string $sql, array $params = []): string
    {
        return Value::str($this->scalar($sql, $params));
    }

    public function scalarInt(string $sql, array $params = []): int
    {
        return Value::int($this->scalar($sql, $params));
    }

    public function transactional(callable $work): mixed
    {
        $this->transactionCount++;

        return $work($this);
    }

    public function lastInsertId(): string
    {
        return $this->lastInsertId;
    }

    /** Find the first recorded call whose SQL contains $needle. */
    public function findCall(string $needle): ?array
    {
        foreach ($this->calls as $call) {
            if (str_contains($call['sql'], $needle)) {
                return $call;
            }
        }

        return null;
    }

    public function calledWith(string $needle): bool
    {
        return $this->findCall($needle) !== null;
    }

    private function dispatch(string $sql, array $params): mixed
    {
        foreach ($this->handlers as $handler) {
            if (str_contains($sql, $handler['needle'])) {
                return ($handler['handler'])($sql, $params);
            }
        }

        return null;
    }
}
