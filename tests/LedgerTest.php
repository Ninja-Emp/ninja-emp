<?php

declare(strict_types=1);

use NinjaEMP\Ledger\JournalEntry;
use NinjaEMP\Ledger\JournalLine;
use NinjaEMP\Ledger\Tender;
use NinjaEMP\Money\Currency;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Ledger');
    $usd = Currency::usd();

    // A balanced entry constructs fine.
    $entry = new JournalEntry(
        '2026-01-02',
        'Test sale',
        'pos',
        'sale-1',
        'key-1',
        [
            JournalLine::debit('undeposited_funds', NinjaEMP\Money\Money::of('10', $usd)),
            JournalLine::credit('sales_revenue', NinjaEMP\Money\Money::of('10', $usd)),
        ],
    );
    $t->assertSame('key-1', $entry->idempotencyKey, 'entry carries idempotency key');
    $t->assertSame(2, count($entry->lines), 'entry has two lines');

    // Unbalanced entry is rejected in PHP before hitting the DB.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => new JournalEntry('2026-01-02', 'Bad', 'pos', null, null, [
            JournalLine::debit('undeposited_funds', NinjaEMP\Money\Money::of('10', $usd)),
            JournalLine::credit('sales_revenue', NinjaEMP\Money\Money::of('9', $usd)),
        ]),
        'unbalanced entry rejected',
    );

    // A line cannot be both debit and credit.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => JournalLine::debit('cash', NinjaEMP\Money\Money::zero($usd)),
        'zero-amount line rejected',
    );

    // Subledger tagging is all-or-nothing.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => JournalLine::debit('vendor_payable_control', NinjaEMP\Money\Money::of('5', $usd), 'party-1', null),
        'party without subledger type rejected',
    );

    // Tender mapping (ADR-0029).
    $t->assertSame('undeposited_funds', Tender::of(Tender::CASH, NinjaEMP\Money\Money::of('1', $usd))->debitRole(), 'cash -> undeposited funds');
    $t->assertSame('card_clearing', Tender::of(Tender::CARD, NinjaEMP\Money\Money::of('1', $usd))->debitRole(), 'card -> clearing');
    $t->assertSame('gift_certificate_control', Tender::of(Tender::GIFT_CERT, NinjaEMP\Money\Money::of('1', $usd), 'p1')->debitRole(), 'gift cert -> liability');
    $t->assertSame('customer_credit', Tender::of(Tender::STORE_CREDIT, NinjaEMP\Money\Money::of('1', $usd), 'p1')->subledgerTypeCode(), 'store credit subledger');
    $t->assertSame('vendor_payable_control', Tender::of(Tender::VENDOR_DRAW, NinjaEMP\Money\Money::of('1', $usd), 'p1')->debitRole(), 'vendor draw -> payable');

    // Liability tender without a party is rejected.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => Tender::of(Tender::GIFT_CERT, NinjaEMP\Money\Money::of('1', $usd))->toJournalLine(),
        'liability tender needs a party',
    );

    // Unknown tender rejected.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => Tender::of('bitcoin', NinjaEMP\Money\Money::of('1', $usd)),
        'unknown tender rejected',
    );

    // Line serialisation shape.
    $line = JournalLine::debit('cash', NinjaEMP\Money\Money::of('7.5', $usd));
    $arr = $line->toArray('acct-uuid');
    $t->assertSame('acct-uuid', $arr['account_id'], 'serialised account id');
    $t->assertSame('7.5000', $arr['debit'], 'serialised debit');
    $t->assertSame('0.0000', $arr['credit'], 'serialised credit');
    $t->assertSame('USD', $arr['currency'], 'serialised currency');
};
