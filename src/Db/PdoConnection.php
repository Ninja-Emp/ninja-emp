<?php

declare(strict_types=1);

namespace NinjaEMP\Db;

use NinjaEMP\Db\Exception\TransactionRequiredException;
use NinjaEMP\Db\Sql\Identifier;
use NinjaEMP\Db\Sql\PlaceholderRewriter;
use NinjaEMP\Db\Sql\Value;
use NinjaEMP\Db\Type\TypeMapper;
use PDO;
use PDOException;
use RuntimeException;
use Throwable;

/**
 * PDO-backed implementation of the DBAL Connection (ADR-0025).
 *
 * Responsibilities:
 *  - rewrite named params to positional (reuse legal),
 *  - issue SET LOCAL tenant/actor/search_path inside every transaction,
 *  - map SQLSTATE to typed exceptions,
 *  - map raw values to typed values (money never becomes a float),
 *  - join nested transactional() calls to the outer transaction (no partial commits).
 *
 * Emulated prepares are the default (PgBouncer transaction-mode safe).
 */
final class PdoConnection implements Connection
{
    private int $transactionDepth = 0;

    public function __construct(
        private readonly PDO $pdo,
        private readonly TenantContext $context,
        private readonly PlaceholderRewriter $rewriter = new PlaceholderRewriter(),
        private readonly TypeMapper $typeMapper = new TypeMapper(),
        private readonly ErrorMapper $errorMapper = new ErrorMapper(),
    ) {
    }

    public function select(string $sql, array $params = []): ResultSet
    {
        $rows = $this->run($sql, $params);

        return new ResultSet(array_map(
            fn (array $raw): Row => new Row($this->typeMapper->map($raw)),
            $rows,
        ));
    }

    public function selectOne(string $sql, array $params = []): Row
    {
        $rows = $this->run($sql, $params);

        if ($rows === []) {
            throw new RuntimeException('selectOne() expected exactly one row, got none.');
        }

        return new Row($this->typeMapper->map($rows[0]));
    }

    public function execute(string $sql, array $params = []): int
    {
        $this->assertInTransaction();

        $rewritten = $this->rewriter->rewrite($sql, $params);

        try {
            $statement = $this->pdo->prepare($rewritten['sql']);
            $statement->execute($rewritten['params']);

            return $statement->rowCount();
        } catch (PDOException $e) {
            throw $this->errorMapper->map($e);
        }
    }

    public function scalar(string $sql, array $params = []): mixed
    {
        $rows = $this->run($sql, $params);

        if ($rows === []) {
            return null;
        }

        $first = $rows[0];

        return $first === [] ? null : reset($first);
    }

    public function scalarString(string $sql, array $params = []): string
    {
        return Value::str($this->scalar($sql, $params));
    }

    public function scalarInt(string $sql, array $params = []): int
    {
        return Value::int($this->scalar($sql, $params));
    }

    /**
     * @template T
     *
     * @param callable(Connection): T $work
     *
     * @return T
     */
    public function transactional(callable $work): mixed
    {
        // Nested calls join the outer transaction (savepoints off by default).
        if ($this->transactionDepth > 0) {
            $this->transactionDepth++;

            try {
                return $work($this);
            } finally {
                $this->transactionDepth--;
            }
        }

        $this->begin();

        try {
            $result = $work($this);
            $this->commit();

            return $result;
        } catch (Throwable $e) {
            $this->rollback();

            throw $e;
        }
    }

    public function lastInsertId(): string
    {
        return Value::str($this->pdo->lastInsertId());
    }

    /**
     * @param array<string, mixed> $params
     *
     * @return list<array<string, mixed>>
     */
    private function run(string $sql, array $params): array
    {
        $this->assertInTransaction();

        $rewritten = $this->rewriter->rewrite($sql, $params);

        try {
            $statement = $this->pdo->prepare($rewritten['sql']);
            $statement->execute($rewritten['params']);

            /** @var list<array<string, mixed>> $rows */
            $rows = $statement->fetchAll(PDO::FETCH_ASSOC);

            return $rows;
        } catch (PDOException $e) {
            throw $this->errorMapper->map($e);
        }
    }

    private function begin(): void
    {
        $this->pdo->beginTransaction();
        $this->transactionDepth = 1;
        $this->applyTenantContext();
    }

    private function commit(): void
    {
        $this->pdo->commit();
        $this->transactionDepth = 0;
    }

    private function rollback(): void
    {
        if ($this->pdo->inTransaction()) {
            $this->pdo->rollBack();
        }
        $this->transactionDepth = 0;
    }

    /**
     * SET LOCAL is transaction-scoped, so it is safe under transaction pooling and
     * cannot leak across tenants. Identifiers are validated; uuids are bound.
     */
    private function applyTenantContext(): void
    {
        $schema = Identifier::of($this->context->schema())->quoted();

        $this->pdo->exec(\sprintf('SET LOCAL search_path = %s, kernel', $schema));

        $this->setLocal('app.tenant_id', $this->context->tenantId());

        if ($this->context->actorId() !== null) {
            $this->setLocal('app.actor_id', $this->context->actorId());
        }
    }

    private function setLocal(string $setting, string $value): void
    {
        $statement = $this->pdo->prepare(\sprintf('SELECT set_config(%s, :value, true)', $this->quoteLiteral($setting)));
        $statement->execute(['value' => $value]);
    }

    private function quoteLiteral(string $value): string
    {
        return "'" . str_replace("'", "''", $value) . "'";
    }

    private function assertInTransaction(): void
    {
        if ($this->transactionDepth === 0) {
            throw new TransactionRequiredException(
                'Tenant-scoped work must run inside transactional(); SET LOCAL requires a transaction.',
            );
        }
    }
}
