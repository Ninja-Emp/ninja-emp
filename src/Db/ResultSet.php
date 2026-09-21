<?php

declare(strict_types=1);

namespace NinjaEMP\Db;

use Countable;
use IteratorAggregate;
use ArrayIterator;
use Traversable;

/**
 * An immutable, in-memory collection of Rows. The DBAL does not stream; result
 * sets are small by design (paged queries are the caller's job).
 *
 * @implements IteratorAggregate<int, Row>
 */
final class ResultSet implements Countable, IteratorAggregate
{
    /** @param list<Row> $rows */
    public function __construct(private readonly array $rows)
    {
    }

    /** @return list<Row> */
    public function rows(): array
    {
        return $this->rows;
    }

    /** @return list<array<string, mixed>> */
    public function toArray(): array
    {
        return array_map(static fn (Row $row): array => $row->toArray(), $this->rows);
    }

    public function first(): ?Row
    {
        return $this->rows[0] ?? null;
    }

    public function isEmpty(): bool
    {
        return $this->rows === [];
    }

    public function count(): int
    {
        return count($this->rows);
    }

    public function getIterator(): Traversable
    {
        return new ArrayIterator($this->rows);
    }
}
