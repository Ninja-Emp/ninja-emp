<?php

declare(strict_types=1);

use NinjaEMP\Money\Allocator;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Exception\CurrencyMismatchException;
use NinjaEMP\Money\Money;
use NinjaEMP\Tests\TestHarness;

/**
 * Mutation-hardening tests for the money core (ADR-0002/0009/0011).
 *
 * These deliberately probe the exact boundaries the mutation score cares about:
 * sign predicates at zero, the half-up rounding boundary, the largest-remainder
 * tie-break, and the negative-total symmetry of the allocator.
 */
return static function (TestHarness $t): void {
    $t->suite('Money (mutation-hardening)');

    $usd = Currency::usd();

    /** @param list<Money> $parts */
    $sum = static function (array $parts) use ($usd): Money {
        $total = Money::zero($usd);

        foreach ($parts as $part) {
            $total = $total->plus($part);
        }

        return $total;
    };

    // --- Sign predicates at the zero boundary --------------------------------
    $zero = Money::of('0', $usd);
    $t->assertTrue($zero->isZero(), 'zero isZero');
    $t->assertFalse($zero->isNegative(), 'zero is not negative');
    $t->assertFalse($zero->isPositive(), 'zero is not positive');

    $pos = Money::of('0.0001', $usd);
    $t->assertFalse($pos->isZero(), 'a positive amount is not zero');
    $t->assertFalse($pos->isNegative(), 'a positive amount is not negative');
    $t->assertTrue($pos->isPositive(), 'a positive amount is positive');

    $neg = Money::of('-0.0001', $usd);
    $t->assertFalse($neg->isZero(), 'a negative amount is not zero');
    $t->assertTrue($neg->isNegative(), 'a negative amount is negative');
    $t->assertFalse($neg->isPositive(), 'a negative amount is not positive');

    // --- abs / negated -------------------------------------------------------
    $t->assertSame('5.0000', Money::of('5', $usd)->abs()->amount(), 'abs of a positive is itself');
    $t->assertSame('5.0000', Money::of('-5', $usd)->abs()->amount(), 'abs of a negative flips sign');
    $t->assertSame('-5.0000', Money::of('5', $usd)->negated()->amount(), 'negated flips a positive');
    $t->assertSame('5.0000', Money::of('-5', $usd)->negated()->amount(), 'negated flips a negative');

    // --- compareTo returns the sign, not just a boolean ----------------------
    $t->assertSame(-1, Money::of('1', $usd)->compareTo(Money::of('2', $usd)), 'compareTo less');
    $t->assertSame(0, Money::of('2', $usd)->compareTo(Money::of('2', $usd)), 'compareTo equal');
    $t->assertSame(1, Money::of('3', $usd)->compareTo(Money::of('2', $usd)), 'compareTo greater');

    // --- greaterThan / lessThan are strict -----------------------------------
    $t->assertFalse(Money::of('2', $usd)->greaterThan(Money::of('2', $usd)), 'greaterThan is strict');
    $t->assertFalse(Money::of('2', $usd)->lessThan(Money::of('2', $usd)), 'lessThan is strict');
    $t->assertTrue(Money::of('1', $usd)->lessThan(Money::of('2', $usd)), 'lessThan true when smaller');

    // --- equals requires BOTH currency and amount ----------------------------
    $t->assertTrue(Money::of('2', $usd)->equals(Money::of('2.0000', $usd)), 'equals true when both match');
    $t->assertFalse(Money::of('2', $usd)->equals(Money::of('3', $usd)), 'equals false when amounts differ');
    $t->assertFalse(
        Money::of('2', $usd)->equals(Money::of('2', Currency::of('EUR'))),
        'equals false when currencies differ',
    );

    // --- Half-up rounding boundary -------------------------------------------
    $t->assertSame('1.0000', Money::of('0.99995', $usd)->amount(), 'rounds up exactly at the half');
    $t->assertSame('0.9999', Money::of('0.99994', $usd)->amount(), 'rounds down just below the half');
    $t->assertSame('1.2345', Money::of('1.2345', $usd)->amount(), 'exactly scale-4 is unchanged');
    $t->assertSame('1.2346', Money::of('1.23455', $usd)->amount(), 'rounds the fifth place up');
    $t->assertSame('0.0000', Money::of('-0.00004', $usd)->amount(), 'a negative that rounds to zero loses its sign');
    $t->assertSame('-1.0000', Money::of('-0.99995', $usd)->amount(), 'negative half-up keeps the sign');

    // --- Construction edge cases ---------------------------------------------
    $t->assertSame('0.0000', Money::zero($usd)->amount(), 'zero factory');
    $t->assertSame('7.0000', Money::of('  7  ', $usd)->amount(), 'trims surrounding whitespace');
    $t->assertSame('7.0000', Money::of(7, $usd)->amount(), 'accepts an int');
    $t->assertSame('7.0000', Money::fromDatabase('7', $usd)->amount(), 'fromDatabase accepts a string');
    $t->assertSame('7.0000', Money::fromDatabase(7, $usd)->amount(), 'fromDatabase accepts an int');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('', $usd), 'rejects an empty amount');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('abc', $usd), 'rejects non-numeric');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('1.', $usd), 'rejects a trailing dot');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('.5', $usd), 'rejects a leading dot');

    // --- Arithmetic exactness ------------------------------------------------
    $t->assertSame('3.0000', Money::of('1', $usd)->plus(Money::of('2', $usd))->amount(), 'plus');
    $t->assertSame('-1.0000', Money::of('1', $usd)->minus(Money::of('2', $usd))->amount(), 'minus can go negative');
    $t->assertSame('6.0000', Money::of('2', $usd)->times('3')->amount(), 'times by a string');
    $t->assertSame('6.0000', Money::of('2', $usd)->times(3)->amount(), 'times by an int');
    $t->assertSame('0.5000', Money::of('1', $usd)->dividedBy('2')->amount(), 'dividedBy');
    $t->assertSame('0.5000', Money::of('1', $usd)->dividedBy(2)->amount(), 'dividedBy by an int');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('1', $usd)->dividedBy('0'), 'division by zero');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('1', $usd)->times('x'), 'malformed multiplier');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('1', $usd)->dividedBy('x'), 'malformed divisor');

    // --- Currency mismatch on every arithmetic path --------------------------
    $eur = Currency::of('EUR');
    $t->assertThrows(CurrencyMismatchException::class, fn () => Money::of('1', $usd)->minus(Money::of('1', $eur)), 'minus checks currency');
    $t->assertThrows(CurrencyMismatchException::class, fn () => Money::of('1', $usd)->compareTo(Money::of('1', $eur)), 'compareTo checks currency');

    // --- format is presentation only -----------------------------------------
    $t->assertSame('1,234.50', Money::of('1234.5', $usd)->format(), 'format defaults to 2 dp with thousands');
    $t->assertSame('1,234.5000', Money::of('1234.5', $usd)->format(4), 'format honours the decimal count');
    $t->assertSame('1234.5000', (string) Money::of('1234.5', $usd), '__toString is the exact string');

    // --- Currency ------------------------------------------------------------
    $t->assertSame('USD', Currency::usd()->code(), 'usd factory');
    $t->assertTrue(Currency::of('USD')->equals(Currency::of('usd')), 'currency equality is case-insensitive');
    $t->assertFalse(Currency::of('USD')->equals(Currency::of('EUR')), 'different currencies are not equal');
    $t->assertThrows(InvalidArgumentException::class, fn () => Currency::of(''), 'rejects an empty currency');

    // ---- Allocator ----------------------------------------------------------

    $t->suite('Allocator (mutation-hardening)');

    // The classic: 0.10 split three ways must sum back to 0.10 exactly.
    $parts = Allocator::allocate(Money::of('0.10', $usd), [1, 1, 1]);
    $t->assertSame('0.0334', $parts[0]->amount(), 'largest remainder gives the extra unit to the first');
    $t->assertSame('0.0333', $parts[1]->amount(), 'second part floored');
    $t->assertSame('0.0333', $parts[2]->amount(), 'third part floored');
    $t->assertSame('0.1000', $sum($parts)->amount(), 'parts sum exactly to the whole');

    // Weighted split: 60/40 of 1.00.
    $parts = Allocator::allocate(Money::of('1.00', $usd), ['0.6', '0.4']);
    $t->assertSame('0.6000', $parts[0]->amount(), '60% share');
    $t->assertSame('0.4000', $parts[1]->amount(), '40% share');

    // A single weight takes the whole.
    $parts = Allocator::allocate(Money::of('9.99', $usd), [1]);
    $t->assertSame('9.9900', $parts[0]->amount(), 'a single part takes everything');

    // Zero weights are allowed as long as the sum is positive.
    $parts = Allocator::allocate(Money::of('1.00', $usd), [1, 0]);
    $t->assertSame('1.0000', $parts[0]->amount(), 'a zero weight receives nothing');
    $t->assertSame('0.0000', $parts[1]->amount(), 'the zero-weight part is zero');

    // Negative total allocates symmetrically.
    $parts = Allocator::allocate(Money::of('-0.10', $usd), [1, 1]);
    $t->assertSame('-0.0500', $parts[0]->amount(), 'negative total, first half');
    $t->assertSame('-0.0500', $parts[1]->amount(), 'negative total, second half');
    $t->assertSame('-0.1000', $sum($parts)->amount(), 'negative parts sum to the negative whole');

    // allocateByRate is the same guarantee.
    $parts = Allocator::allocateByRate(Money::of('0.10', $usd), [1, 1, 1]);
    $t->assertSame('0.1000', $sum($parts)->amount(), 'allocateByRate sums exactly');

    // Tie-break is by original index (stable), not by weight order.
    $parts = Allocator::allocate(Money::of('0.0002', $usd), [1, 1]);
    $t->assertSame('0.0001', $parts[0]->amount(), 'tie-break favours the lower index');
    $t->assertSame('0.0001', $parts[1]->amount(), 'tie-break second part');

    // Validation.
    $t->assertThrows(InvalidArgumentException::class, fn () => Allocator::allocate(Money::of('1', $usd), []), 'rejects zero parts');
    $t->assertThrows(InvalidArgumentException::class, fn () => Allocator::allocate(Money::of('1', $usd), [1, -1]), 'rejects a negative weight');
    $t->assertThrows(InvalidArgumentException::class, fn () => Allocator::allocate(Money::of('1', $usd), [0, 0]), 'rejects a zero weight sum');
    $t->assertThrows(InvalidArgumentException::class, fn () => Allocator::allocate(Money::of('1', $usd), ['x']), 'rejects a malformed weight');
    $t->assertThrows(InvalidArgumentException::class, fn () => Allocator::allocate(Money::of('1', $usd), ['']), 'rejects an empty weight');

    // Integer weights are accepted alongside strings.
    $parts = Allocator::allocate(Money::of('3.00', $usd), [1, '2']);
    $t->assertSame('1.0000', $parts[0]->amount(), 'mixed int/string weights, first');
    $t->assertSame('2.0000', $parts[1]->amount(), 'mixed int/string weights, second');
};
