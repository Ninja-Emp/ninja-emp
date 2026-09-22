<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Type;

use NinjaEMP\Db\Sql\Value;

use DateTimeImmutable;
use DateTimeZone;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;

/**
 * Maps raw PDO values to typed PHP values (ADR-0025 §6).
 *
 * The money-critical rule: a NUMERIC column comes back from PDO as a *string*.
 * We wrap it in Money (string-backed) and never let it become a float. The
 * mapper is told which columns are money and which currency they are in, because
 * the DBAL does not introspect the schema at runtime (a non-goal).
 */
final class TypeMapper
{
    /**
     * @param array<string, mixed> $raw raw PDO row
     * @param array<string, string> $moneyColumns column => currency code
     * @param list<string> $jsonColumns columns holding jsonb
     * @param list<string> $boolColumns columns holding boolean
     * @param list<string> $intColumns columns holding bigint/int
     * @param list<string> $timeColumns columns holding timestamptz/date
     *
     * @return array<string, mixed>
     */
    public function map(
        array $raw,
        array $moneyColumns = [],
        array $jsonColumns = [],
        array $boolColumns = [],
        array $intColumns = [],
        array $timeColumns = [],
    ): array {
        $mapped = [];

        foreach ($raw as $column => $value) {
            if ($value === null) {
                $mapped[$column] = null;
                continue;
            }

            if (isset($moneyColumns[$column])) {
                $mapped[$column] = \is_string($value) || \is_int($value) || \is_float($value)
                    ? Money::fromDatabase($value, Currency::of($moneyColumns[$column]))
                    : null;
                continue;
            }

            if (\in_array($column, $jsonColumns, true)) {
                $mapped[$column] = $this->decodeJson($value);
                continue;
            }

            if (\in_array($column, $boolColumns, true)) {
                $mapped[$column] = $this->toBool($value);
                continue;
            }

            if (\in_array($column, $intColumns, true)) {
                $mapped[$column] = $this->toInt($value);
                continue;
            }

            if (\in_array($column, $timeColumns, true)) {
                $mapped[$column] = $this->toDateTime($value);
                continue;
            }

            $mapped[$column] = $value;
        }

        return $mapped;
    }

    /**
     * @return array<mixed>|null
     */
    private function decodeJson(mixed $value): ?array
    {
        if (\is_array($value)) {
            return $value;
        }

        $decoded = json_decode(Value::str($value), true);

        return \is_array($decoded) ? $decoded : null;
    }

    private function toBool(mixed $value): bool
    {
        if (\is_bool($value)) {
            return $value;
        }

        return \in_array(Value::str($value), ['1', 't', 'true', 'TRUE', 'y', 'yes'], true);
    }

    /**
     * bigint values beyond PHP_INT_MAX stay as strings to avoid silent truncation.
     */
    private function toInt(mixed $value): int|string
    {
        if (\is_int($value)) {
            return $value;
        }

        $string = Value::num($value);

        if (bccomp($string, (string) PHP_INT_MAX, 0) > 0 || bccomp($string, (string) PHP_INT_MIN, 0) < 0) {
            return $string;
        }

        return Value::int($string);
    }

    private function toDateTime(mixed $value): DateTimeImmutable
    {
        if ($value instanceof DateTimeImmutable) {
            return $value;
        }

        $utc = new DateTimeZone('UTC');

        // A bare date (YYYY-MM-DD) becomes midnight UTC.
        if (preg_match('/^\d{4}-\d{2}-\d{2}$/', Value::str($value)) === 1) {
            return new DateTimeImmutable(Value::str($value) . ' 00:00:00', $utc);
        }

        return new DateTimeImmutable(Value::str($value), $utc);
    }
}
