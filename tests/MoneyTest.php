<?php

declare(strict_types=1);

use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Exception\CurrencyMismatchException;
use NinjaEMP\Money\Money;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Money');

    $usd = Currency::usd();

    // Construction + canonical scale-4 string.
    $t->assertSame('12.5000', Money::of('12.5', $usd)->amount(), 'normalises to scale 4');
    $t->assertSame('0.0000', Money::of(0, $usd)->amount(), 'int zero');
    $t->assertSame('100.0000', Money::of(100, $usd)->amount(), 'int amount');

    // Never float.
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::fromDatabase(1.5, $usd), 'rejects float from DB');
    $t->assertThrows(InvalidArgumentException::class, fn () => Money::of('1.2.3', $usd), 'rejects malformed');

    // Exact arithmetic (the classic float trap: 0.1 + 0.2).
    $sum = Money::of('0.1', $usd)->plus(Money::of('0.2', $usd));
    $t->assertSame('0.3000', $sum->amount(), '0.1 + 0.2 is exactly 0.3');

    $t->assertSame('0.1000', Money::of('0.3', $usd)->minus(Money::of('0.2', $usd))->amount(), 'subtraction exact');
    $t->assertSame('2.5000', Money::of('1.25', $usd)->times('2')->amount(), 'multiply exact');
    $t->assertSame('0.3333', Money::of('1', $usd)->dividedBy('3')->amount(), 'divide truncates at scale 4');

    // Rounding half-up at the boundary, no float.
    $t->assertSame('1.0000', Money::of('0.99999', $usd)->amount(), 'rounds half-up at scale 4');
    $t->assertSame('0.9999', Money::of('0.99994', $usd)->amount(), 'rounds down below half');

    // Sign handling.
    $t->assertTrue(Money::of('-5', $usd)->isNegative(), 'negative detection');
    $t->assertSame('5.0000', Money::of('-5', $usd)->abs()->amount(), 'abs');
    $t->assertSame('5.0000', Money::of('-5', $usd)->negated()->amount(), 'negated');

    // Comparison.
    $t->assertTrue(Money::of('2', $usd)->greaterThan(Money::of('1', $usd)), 'greaterThan');
    $t->assertTrue(Money::of('1', $usd)->equals(Money::of('1.0000', $usd)), 'equals ignores trailing zeros');

    // Currency safety.
    $t->assertThrows(
        CurrencyMismatchException::class,
        fn () => Money::of('1', $usd)->plus(Money::of('1', Currency::of('EUR'))),
        'refuses cross-currency arithmetic',
    );

    // Currency validation.
    $t->assertSame('USD', Currency::of('usd')->code(), 'currency normalises case');
    $t->assertThrows(InvalidArgumentException::class, fn () => Currency::of('US'), 'rejects short code');
    $t->assertThrows(InvalidArgumentException::class, fn () => Currency::of('US1'), 'rejects non-alpha');
    $t->assertTrue(Currency::of('EUR')->isKnown(), 'EUR is known');
    $t->assertFalse(Currency::of('XYZ')->isKnown(), 'XYZ is unknown but valid');
};
