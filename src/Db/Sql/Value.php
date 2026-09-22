<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Sql;

/**
 * Safe narrowing of untyped database values.
 *
 * PDO hands back `mixed` for every column. Casting `mixed` directly is unsafe
 * (the value could be an array or object) and PHPStan level 10 rejects it. These
 * helpers narrow a `mixed` value to a concrete scalar with an explicit,
 * documented fallback, so the rest of the codebase can stay strictly typed
 * without sprinkling `is_*` guards everywhere.
 *
 * They are deliberately total: they never throw. A malformed value degrades to
 * the caller-supplied default rather than corrupting a money string.
 */
final class Value
{
    /** Narrow to a string. Non-scalars (and null) yield $default. */
    public static function str(mixed $value, string $default = ''): string
    {
        if (\is_string($value)) {
            return $value;
        }

        if (\is_int($value) || \is_float($value) || \is_bool($value)) {
            return (string) $value;
        }

        return $default;
    }

    /** Narrow to a nullable string. Null stays null; non-scalars yield null. */
    public static function nullableStr(mixed $value): ?string
    {
        if ($value === null) {
            return null;
        }

        if (\is_string($value)) {
            return $value;
        }

        if (\is_int($value) || \is_float($value) || \is_bool($value)) {
            return (string) $value;
        }

        return null;
    }

    /**
     * Narrow to a numeric string suitable for bcmath.
     *
     * @param numeric-string $default
     *
     * @return numeric-string
     */
    public static function num(mixed $value, string $default = '0'): string
    {
        if (\is_int($value) || \is_float($value)) {
            return (string) $value;
        }

        if (\is_string($value) && is_numeric($value)) {
            return $value;
        }

        return $default;
    }

    /** Narrow to an int. Non-numerics yield $default. */
    public static function int(mixed $value, int $default = 0): int
    {
        if (\is_int($value)) {
            return $value;
        }

        if (\is_float($value)) {
            return (int) $value;
        }

        if (\is_string($value) && is_numeric($value)) {
            return (int) $value;
        }

        return $default;
    }

    /** Narrow to a float. Non-numerics yield $default. */
    public static function float(mixed $value, float $default = 0.0): float
    {
        if (\is_int($value) || \is_float($value)) {
            return (float) $value;
        }

        if (\is_string($value) && is_numeric($value)) {
            return (float) $value;
        }

        return $default;
    }

    /** Narrow to a bool. */
    public static function bool(mixed $value, bool $default = false): bool
    {
        if (\is_bool($value)) {
            return $value;
        }

        if (\is_int($value) || \is_float($value)) {
            return $value !== 0 && $value !== 0.0;
        }

        if (\is_string($value)) {
            return filter_var($value, \FILTER_VALIDATE_BOOL, \FILTER_NULL_ON_FAILURE) ?? $default;
        }

        return $default;
    }
}
