<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Sql;

use InvalidArgumentException;

/**
 * Validates and quotes SQL identifiers (schema/table/column names).
 *
 * Rule (ADR-0025 §5): never interpolate *values* into SQL. Identifiers are the
 * one thing that cannot be bound, so they are validated against a strict pattern
 * and double-quoted. Anything that fails validation is rejected outright.
 */
final class Identifier
{
    private const PATTERN = '/^[a-z_][a-z0-9_]*$/';

    private function __construct(private readonly string $name)
    {
    }

    /**
     * @throws InvalidArgumentException when the identifier is not safe.
     */
    public static function of(string $name): self
    {
        if (preg_match(self::PATTERN, $name) !== 1) {
            throw new InvalidArgumentException(\sprintf(
                'Unsafe SQL identifier: "%s" (must match %s).',
                $name,
                self::PATTERN,
            ));
        }

        return new self($name);
    }

    public static function isValid(string $name): bool
    {
        return preg_match(self::PATTERN, $name) === 1;
    }

    public function name(): string
    {
        return $this->name;
    }

    /** Double-quoted, safe to interpolate into SQL. */
    public function quoted(): string
    {
        return '"' . $this->name . '"';
    }

    public function __toString(): string
    {
        return $this->quoted();
    }
}
