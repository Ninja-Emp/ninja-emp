<?php

declare(strict_types=1);

namespace NinjaEMP\Db;

use ArrayAccess;
use ArrayIterator;
use Countable;
use IteratorAggregate;
use LogicException;
use OutOfBoundsException;
use Traversable;

/**
 * A single result row with typed values (see TypeMapper). Immutable.
 *
 * @implements ArrayAccess<string, mixed>
 * @implements IteratorAggregate<string, mixed>
 */
final class Row implements ArrayAccess, Countable, IteratorAggregate
{
    /** @param array<string, mixed> $values */
    public function __construct(private readonly array $values)
    {
    }

    /** @return array<string, mixed> */
    public function toArray(): array
    {
        return $this->values;
    }

    public function has(string $column): bool
    {
        return \array_key_exists($column, $this->values);
    }

    public function get(string $column, mixed $default = null): mixed
    {
        return $this->values[$column] ?? $default;
    }

    /** @throws OutOfBoundsException when the column is absent. */
    public function require(string $column): mixed
    {
        if (!\array_key_exists($column, $this->values)) {
            throw new OutOfBoundsException(\sprintf('Column "%s" not present in row.', $column));
        }

        return $this->values[$column];
    }

    public function count(): int
    {
        return \count($this->values);
    }

    public function getIterator(): Traversable
    {
        return new ArrayIterator($this->values);
    }

    public function offsetExists(mixed $offset): bool
    {
        return \is_string($offset) && \array_key_exists($offset, $this->values);
    }

    public function offsetGet(mixed $offset): mixed
    {
        return $this->values[$offset] ?? null;
    }

    /**
     * @SuppressWarnings("UnusedFormalParameter") required by ArrayAccess; the
     *   row is immutable so the arguments are intentionally ignored.
     */
    public function offsetSet(mixed $offset, mixed $value): void
    {
        throw new LogicException('Row is immutable.');
    }

    /**
     * @SuppressWarnings("UnusedFormalParameter") required by ArrayAccess; the
     *   row is immutable so the argument is intentionally ignored.
     */
    public function offsetUnset(mixed $offset): void
    {
        throw new LogicException('Row is immutable.');
    }
}
