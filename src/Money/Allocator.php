<?php

declare(strict_types=1);

namespace NinjaEMP\Money;

use InvalidArgumentException;
use NinjaEMP\Db\Sql\Value;

/**
 * Exact allocation of a whole into parts (ADR-0009).
 *
 * Splitting money is where rounding bugs are born. If you compute each part as
 * `total * share` independently and round each one, the parts will not sum back
 * to the whole — a cent appears or vanishes. Over thousands of sales that is a
 * real, unexplained ledger imbalance.
 *
 * This allocator uses the largest-remainder method: every part is floored to the
 * storage scale (4 dp), then the leftover units are handed out one at a time to
 * the parts with the largest fractional remainders. The parts are guaranteed to
 * sum to the whole, exactly, with no adjustment line required.
 *
 * It is pure and float-free: all arithmetic is bcmath on decimal strings.
 */
final class Allocator
{
    /**
     * Split $total across $weights so the parts sum exactly to $total.
     *
     * @param list<string|int> $weights non-negative relative weights (e.g. [1,1,1] or ['0.6','0.4'])
     *
     * @throws InvalidArgumentException on empty weights, negative weights, or a zero weight sum
     *
     * @return list<Money> one part per weight, in the same order
     */
    public static function allocate(Money $total, array $weights): array
    {
        if ($weights === []) {
            throw new InvalidArgumentException('Cannot allocate across zero parts.');
        }

        /** @var numeric-string $sum */
        $sum = '0';

        foreach ($weights as $w) {
            $w = self::normaliseWeight($w);

            if (bccomp($w, '0', 12) < 0) {
                throw new InvalidArgumentException('Allocation weights must be non-negative.');
            }
            $sum = bcadd($sum, $w, 12);
        }

        if (bccomp($sum, '0', 12) === 0) {
            throw new InvalidArgumentException('Allocation weights sum to zero.');
        }

        // Work on the magnitude; re-apply the sign at the end so a negative total
        // (a credit split) allocates symmetrically.
        $negative = $total->isNegative();
        $magnitude = $total->abs()->amount();

        $scale = Money::SCALE;
        /** @var numeric-string $floorSum */
        $floorSum = '0';
        /** @var array<int, numeric-string> $floors */
        $floors = [];
        /** @var list<array{index:int, remainder:numeric-string}> $remainders */
        $remainders = [];

        foreach ($weights as $i => $w) {
            $w = self::normaliseWeight($w);
            // Exact share at high precision, then floor to the storage scale.
            $exact = bcdiv(bcmul($magnitude, $w, 16), $sum, 16);
            $floor = self::truncate($exact, $scale);
            $floors[$i] = $floor;
            $floorSum = bcadd($floorSum, $floor, $scale);
            $remainders[] = ['index' => $i, 'remainder' => bcsub($exact, $floor, 16)];
        }

        // Leftover is a whole number of 0.0001 units (never negative).
        $leftover = bcsub($magnitude, $floorSum, $scale);
        $units = (int) bcmul($leftover, '10000', 0);

        // Hand out the leftover units to the largest fractional remainders.
        usort($remainders, static function (array $a, array $b): int {
            $cmp = bccomp($b['remainder'], $a['remainder'], 16);

            return $cmp !== 0 ? $cmp : $a['index'] <=> $b['index'];
        });

        for ($k = 0; $k < $units; $k++) {
            $idx = $remainders[$k]['index'];
            $floors[$idx] = bcadd($floors[$idx], '0.0001', $scale);
        }

        $parts = [];

        foreach ($floors as $amount) {
            $amount = $negative ? bcmul($amount, '-1', $scale) : $amount;
            $parts[] = Money::of($amount, $total->currency());
        }

        return $parts;
    }

    /**
     * Split $total in proportion to $weights expressed as percentages (0..1).
     * Convenience wrapper; identical guarantees.
     *
     * @param list<string|int> $rates
     *
     * @return list<Money>
     */
    public static function allocateByRate(Money $total, array $rates): array
    {
        return self::allocate($total, $rates);
    }

    /** @return numeric-string */
    private static function normaliseWeight(string|int $weight): string
    {
        $weight = \is_int($weight) ? Value::str($weight) : trim($weight);

        if ($weight === '' || preg_match('/^-?\d+(\.\d+)?$/', $weight) !== 1) {
            throw new InvalidArgumentException(\sprintf('Malformed allocation weight: "%s".', $weight));
        }

        return Value::num($weight);
    }

    /**
     * Truncate (floor toward zero) a decimal string to $scale places, no rounding.
     *
     * @return numeric-string
     */
    private static function truncate(string $number, int $scale): string
    {
        $negative = str_starts_with($number, '-');

        if ($negative) {
            $number = substr($number, 1);
        }

        if (str_contains($number, '.')) {
            [$int, $frac] = explode('.', $number, 2);
        } else {
            $int = $number;
            $frac = '';
        }

        $frac = str_pad(substr($frac, 0, $scale), $scale, '0');

        /** @var numeric-string $result */
        $result = $scale > 0 ? $int . '.' . $frac : $int;

        return $negative ? Value::num('-' . $result) : $result;
    }
}
