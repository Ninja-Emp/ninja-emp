<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use InvalidArgumentException;
use NinjaEMP\Domain\OpenItem\OpenItemService;
use NinjaEMP\Domain\Pos\ShiftService;
use NinjaEMP\Domain\Reporting\ReportingService;
use NinjaEMP\Domain\StoredValue\StoredValueService;
use NinjaEMP\Tests\Support\FakeConnection;

require_once __DIR__ . '/Support/FakeConnection.php';

/**
 * Tests for the domain modules built on the ledger: shifts/registers, open
 * items, stored value, and reporting. They exercise the orchestration — the SQL
 * issued, the money computed, the posting functions called — against a fake
 * Connection, so they run without a live PostgreSQL.
 */
return static function (TestHarness $t): void {
    // ---- ShiftService -----------------------------------------------------

    $t->suite('ShiftService');

    $conn = new FakeConnection();
    $conn->on('INSERT INTO register', static fn () => [['id' => 'reg-1']]);
    $conn->on('INSERT INTO shift', static fn () => [['id' => 'shift-1']]);
    $conn->on('post_shift_close', static fn () => 'entry-close-1');

    $shifts = new ShiftService($conn);

    $regId = $shifts->createRegister('R1', 'Front Counter', 'loc-1');
    $t->assertSame('reg-1', $regId, 'createRegister returns the register id');
    $t->assertTrue($conn->calledWith('INSERT INTO register'), 'createRegister inserts a register');

    $shiftId = $shifts->openShift('reg-1', '200.00', 'party-1');
    $t->assertSame('shift-1', $shiftId, 'openShift returns the shift id');
    $openCall = $conn->findCall('INSERT INTO shift');
    $t->assertSame('200.0000', $openCall['params']['float'], 'opening float is normalised to 4dp');

    $entry = $shifts->closeShift('shift-1', '250.00', '2026-01-31', 'key-1');
    $t->assertSame('entry-close-1', $entry, 'closeShift returns the over/short entry id');
    $closeCall = $conn->findCall('post_shift_close');
    $t->assertSame('250.00', $closeCall['params']['counted'], 'closeShift passes the counted cash');
    $t->assertSame('key-1', $closeCall['params']['key'], 'closeShift passes the idempotency key');

    // A balanced drawer posts nothing (post_shift_close returns NULL).
    $conn2 = new FakeConnection();
    $conn2->on('post_shift_close', static fn () => null);
    $t->assertSame(null, (new ShiftService($conn2))->closeShift('shift-2', '100.00'), 'balanced drawer posts nothing');

    // previewClose computes expected = float + cash-in, over/short = counted - expected.
    $conn3 = new FakeConnection();
    $conn3->on('SELECT opening_float', static fn () => [['opening_float' => '200.0000', 'currency' => 'USD']]);
    $conn3->on('SELECT COALESCE(sum(pt.amount)', static fn () => '150.0000');
    $preview = (new ShiftService($conn3))->previewClose('shift-1', '360.00');
    $t->assertSame('200.0000', $preview['opening_float'], 'preview opening float');
    $t->assertSame('150.0000', $preview['cash_in'], 'preview cash in');
    $t->assertSame('350.0000', $preview['expected'], 'preview expected = float + cash in');
    $t->assertSame('10.0000', $preview['over_short'], 'preview over/short = counted - expected');

    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new ShiftService(new FakeConnection()))->openShift('reg-1', '-1.00'),
        'a negative opening float is rejected',
    );

    // ---- OpenItemService --------------------------------------------------

    $t->suite('OpenItemService');

    $conn = new FakeConnection();
    $conn->on('open_item_create', static fn () => 'oi-1');
    $conn->on('apply_payment', static fn () => 'entry-pay-1');
    $conn->on('write_off_open_item', static fn () => 'entry-wo-1');

    $openItems = new OpenItemService($conn);

    $oi = $openItems->create('ar', 'party-1', 'rent', '500.00', 'USD', '2026-01-01', '2026-01-31', 'lease-1', 'INV-1', 'je-1');
    $t->assertSame('oi-1', $oi, 'create returns the open item id');
    $createCall = $conn->findCall('open_item_create');
    $t->assertSame('ar', $createCall['params']['subledger'], 'create passes the subledger type');
    $t->assertSame('500.00', $createCall['params']['amount'], 'create passes the amount');

    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $openItems->create('ar', 'party-1', 'rent', '0.00', 'USD', '2026-01-01'),
        'a zero open item is rejected',
    );

    $payEntry = $openItems->applyPayment('party-1', 'ar', '500.00', '2026-02-01', 'key-pay');
    $t->assertSame('entry-pay-1', $payEntry, 'applyPayment returns the entry id');
    $payCall = $conn->findCall('apply_payment');
    $t->assertSame('ar', $payCall['params']['subledger'], 'applyPayment passes the subledger type');

    $woEntry = $openItems->writeOff('oi-1', '2026-03-01', null, 'uncollectible', 'key-wo');
    $t->assertSame('entry-wo-1', $woEntry, 'writeOff returns the entry id');

    // aging buckets.
    $conn4 = new FakeConnection();
    $conn4->on('SELECT', static fn () => [[
        'current' => '100.0000', 'd1_30' => '50.0000', 'd31_60' => '25.0000',
        'd61_90' => '10.0000', 'd90_plus' => '5.0000',
    ]]);
    $aging = (new OpenItemService($conn4))->aging('ar', '2026-02-01');
    $t->assertSame('100.0000', $aging['current'], 'aging current bucket');
    $t->assertSame('5.0000', $aging['90_plus'], 'aging 90+ bucket');

    // ---- StoredValueService -----------------------------------------------

    $t->suite('StoredValueService');

    $conn = new FakeConnection();
    $conn->on('issue_stored_value', static fn () => 'sv-1');
    $conn->on('redeem_stored_value', static fn () => 'entry-redeem-1');
    $conn->on('recognize_breakage', static fn () => 'entry-break-1');

    $sv = new StoredValueService($conn);

    $id = $sv->issue(StoredValueService::GIFT_CERTIFICATE, 'GC-100', '50.00', 'party-1', '2026-01-01');
    $t->assertSame('sv-1', $id, 'issue returns the stored value id');
    $issueCall = $conn->findCall('issue_stored_value');
    $t->assertSame('gift_certificate', $issueCall['params']['kind'], 'issue passes the instrument kind');
    $t->assertSame('true', $issueCall['params']['cash'], 'issue defaults to paid-with-cash');

    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $sv->issue('bogus', 'X', '10.00'),
        'an unknown instrument kind is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $sv->issue(StoredValueService::STORE_CREDIT, 'SC-1', '0.00'),
        'a non-positive amount is rejected',
    );

    $redeemEntry = $sv->redeem('GC-100', '25.00', '2026-02-01', 'sale-1');
    $t->assertSame('entry-redeem-1', $redeemEntry, 'redeem returns the entry id');

    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $sv->redeem('GC-100', '25.00'),
        'a redemption without a sale or entry is rejected',
    );

    $breakEntry = $sv->recognizeBreakage('2026-12-31', 'key-break');
    $t->assertSame('entry-break-1', $breakEntry, 'recognizeBreakage returns the entry id when opted in');

    $conn5 = new FakeConnection();
    $conn5->on('recognize_breakage', static fn () => null);
    $t->assertSame(null, (new StoredValueService($conn5))->recognizeBreakage(), 'breakage is a no-op when not opted in');

    // ---- ReportingService -------------------------------------------------

    $t->suite('ReportingService');

    $conn = new FakeConnection();
    $conn->on('income_statement', static fn () => [
        ['account_type_code' => 'revenue', 'account_code' => '4000', 'account_name' => 'Sales', 'amount' => '1000.0000', 'sort_order' => 10],
    ]);
    $conn->on('balance_sheet_check', static fn () => [['balanced' => true, 'difference' => '0.0000']]);
    $conn->on('net_income', static fn () => '250.0000');
    $conn->on('FROM sale', static fn () => [[
        'sale_count' => 3, 'subtotal' => '300.0000', 'discount_total' => '0.0000',
        'tax_total' => '24.0000', 'total' => '324.0000', 'refunds' => '0.0000',
    ]]);
    $conn->on('FROM inventory_item', static fn () => [[
        'active_items' => 10, 'units_on_hand' => '40.0000', 'total_value' => '800.0000',
    ]]);

    $reports = new ReportingService($conn);

    $pl = $reports->incomeStatement('2026-01-01', '2026-01-31');
    $t->assertSame(1, \count($pl), 'income statement returns rows');
    $t->assertSame('Sales', $pl[0]['account_name'], 'income statement row name');

    $t->assertSame('250.0000', $reports->netIncome('2026-01-01', '2026-01-31'), 'net income figure');

    $check = $reports->balanceSheetCheck('2026-01-31');
    $t->assertSame(true, $check['balanced'], 'balance sheet check reports balanced');

    $summary = $reports->salesSummary('2026-01-01', '2026-01-31');
    $t->assertSame(3, $summary['sale_count'], 'sales summary count');
    $t->assertSame('324.0000', $summary['total'], 'sales summary total');

    $valuation = $reports->inventoryValuation();
    $t->assertSame('800.0000', $valuation['total_value'], 'inventory valuation total');
};
