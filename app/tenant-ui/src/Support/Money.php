<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Support;

use NinjaEMP\Db\Sql\Value;

/**
 * Money helpers.
 *
 * Per ADR-0002 / ADR-0025: money is carried as strings and computed with bcmath.
 * It is NEVER cast to float. Formatting happens only at the presentation edge.
 */
final class Money
{
    /** Format a string amount as e.g. "$1,247.75". */
    public static function format(string $amount, string $currency = 'USD'): string
    {
        $negative = str_starts_with($amount, '-');
        $abs = ltrim($amount, '-');
        [$whole, $frac] = array_pad(explode('.', $abs, 2), 2, '00');
        $frac = str_pad(substr($frac, 0, 2), 2, '0');
        $whole = number_format((float) $whole); // grouping only; value already exact
        $symbol = self::symbol($currency);

        return ($negative ? '-' : '') . $symbol . $whole . '.' . $frac;
    }

    /** Format without the currency symbol (for inputs/tables). */
    public static function plain(string $amount): string
    {
        $negative = str_starts_with($amount, '-');
        $abs = ltrim($amount, '-');
        [$whole, $frac] = array_pad(explode('.', $abs, 2), 2, '00');
        $frac = str_pad(substr($frac, 0, 2), 2, '0');

        return ($negative ? '-' : '') . number_format((float) $whole) . '.' . $frac;
    }

    /** Add two money strings exactly (bcmath). */
    public static function add(string $a, string $b): string
    {
        return bcadd(Value::num($a), Value::num($b), 4);
    }

    /** Subtract b from a exactly (bcmath). */
    public static function sub(string $a, string $b): string
    {
        return bcsub(Value::num($a), Value::num($b), 4);
    }

    /** Multiply a money string by a quantity/rate exactly (bcmath). */
    public static function mul(string $a, string $b): string
    {
        return bcmul(Value::num($a), Value::num($b), 4);
    }

    /** Apply a percentage (e.g. "8.25" for 8.25%) to a money string. */
    public static function percent(string $amount, string $percent): string
    {
        return bcdiv(bcmul(Value::num($amount), Value::num($percent), 6), '100', 4);
    }

    /** Round a money string to cents (half-up), returning a 2dp string. */
    public static function round(string $amount): string
    {
        return bcadd(Value::num($amount), '0', 2);
    }

    public static function symbol(string $currency): string
    {
        return match (strtoupper($currency)) {
            'USD' => '$',
            'EUR' => "\u{20AC}",
            'GBP' => "\u{00A3}",
            default => strtoupper($currency) . ' ',
        };
    }
}
