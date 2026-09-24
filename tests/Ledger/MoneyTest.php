<?php

declare(strict_types=1);

namespace EmpPos\Tests\Ledger;

use EmpPos\Shared\Ledger\JournalLine;
use EmpPos\Shared\Ledger\JournalRules;
use EmpPos\Shared\Ledger\LedgerError;
use EmpPos\Shared\Ledger\Money;
use EmpPos\Shared\Ledger\Posting;
use PHPUnit\Framework\TestCase;

final class MoneyTest extends TestCase
{
    public function testCanonicalMinorString(): void
    {
        $money = Money::fromMinorString('100', 'USD');
        self::assertSame(100, $money->minor());
        self::assertSame('100', $money->minorString());
        self::assertSame('USD', $money->currency());
        self::assertFalse($money->isZero());
        self::assertSame(150, $money->plus(Money::of(50, 'USD'))->minor());
    }

    public function testZeroIsCanonical(): void
    {
        self::assertTrue(Money::fromMinorString('0', 'CAD')->isZero());
        self::assertSame(0, Money::zero('EUR')->minor());
    }

    public function testRejectsNonCanonicalStrings(): void
    {
        foreach (['', '100.9', '1e2', '-1', '0100', ' 10'] as $minor) {
            try {
                Money::fromMinorString($minor, 'USD');
                self::fail($minor);
            } catch (LedgerError $error) {
                self::assertSame('INVALID_MONEY', $error->errorCode());
            }
        }
    }

    public function testRejectsTooLargeAndBadCurrency(): void
    {
        self::assertSame(PHP_INT_MAX, Money::fromMinorString((string) PHP_INT_MAX, 'USD')->minor());
        self::assertSame(1000000000000000000, Money::fromMinorString('1000000000000000000', 'USD')->minor());
        try {
            Money::fromMinorString('9223372036854775808', 'USD');
            self::fail('too large');
        } catch (LedgerError $error) {
            self::assertSame('INVALID_MONEY', $error->errorCode());
        }
        try {
            Money::of(-1, 'USD');
            self::fail('negative');
        } catch (LedgerError $error) {
            self::assertSame('INVALID_MONEY', $error->errorCode());
        }
        try {
            Money::of(1, 'GBP');
            self::fail('currency');
        } catch (LedgerError $error) {
            self::assertSame('CURRENCY_MISMATCH', $error->errorCode());
        }
        try {
            Money::of(1, 'USD')->plus(Money::of(1, 'EUR'));
            self::fail('mix');
        } catch (LedgerError $error) {
            self::assertSame('CURRENCY_MISMATCH', $error->errorCode());
        }
    }
}
