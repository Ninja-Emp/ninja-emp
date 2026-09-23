<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use NinjaEMP\Domain\Pos\PosService;
use NinjaEMP\Domain\Pos\SaleLineInput;
use NinjaEMP\Domain\Pos\SaleRequest;
use NinjaEMP\Domain\Pos\TenderInput;
use NinjaEMP\Tests\Support\FakeConnection;

require_once __DIR__ . '/Support/FakeConnection.php';

/**
 * Idempotency-key derivation and the `??` defaults in the POS service.
 *
 * Every posting path derives a stable key when the caller does not supply one,
 * so a retried request returns the same ledger entry instead of double-posting.
 * These tests pin the exact key and date handed to each posting function, which
 * is what makes the derivation (and its null-coalescing defaults) observable.
 */
return static function (TestHarness $t): void {
    $t->suite('PosService (idempotency keys)');

    // A ring-up with no explicit key derives one from the request content.
    $conn = new FakeConnection();
    $conn->on('INSERT INTO sale_line', static fn () => null);
    $conn->on('INSERT INTO sale', static fn () => [['id' => 'sale-1', 'sale_no' => '1001']]);
    $conn->on('INSERT INTO payment_tender', static fn () => null);
    $conn->on('INSERT INTO payment', static fn () => [['id' => 'pay-1']]);
    $conn->on('post_sale_inventory', static fn () => 1);
    $conn->on('post_sale(', static fn () => 'entry-1');

    $request = new SaleRequest(
        lines: [new SaleLineInput(SaleLineInput::OWNED, 'Widget', '2', '10.00', inventoryItemId: 'inv-1')],
        tenders: [new TenderInput('cash', '20.00')],
        registerId: 'reg-1',
        shiftId: 'shift-1',
        saleDate: '2026-03-15',
    );

    (new PosService($conn))->ringUp($request);

    $postSale = $conn->findCall('post_sale(');
    $t->assertTrue($postSale !== null, 'ringUp posts the sale');

    // Independent oracle for the derived key (mirrors deriveKey's contract).
    $parts = [
        '2026-03-15',
        'USD',
        'reg-1',
        'shift-1',
        '',
        'owned||2|10.00|0|||inv-1|0',
        'cash|20.00|',
    ];
    $expectedKey = 'pos_sale:' . hash('sha256', implode("\n", $parts));

    $t->assertSame($expectedKey, $postSale['params']['key'], 'ringUp derives the documented idempotency key');
    $t->assertSame('2026-03-15', $postSale['params']['date'], 'ringUp uses the request sale date when given');

    // An explicit key is passed through unchanged.
    $conn2 = new FakeConnection();
    $conn2->on('INSERT INTO sale_line', static fn () => null);
    $conn2->on('INSERT INTO sale', static fn () => [['id' => 'sale-2', 'sale_no' => '1002']]);
    $conn2->on('INSERT INTO payment_tender', static fn () => null);
    $conn2->on('INSERT INTO payment', static fn () => [['id' => 'pay-2']]);
    $conn2->on('post_sale_inventory', static fn () => 1);
    $conn2->on('post_sale(', static fn () => 'entry-2');

    (new PosService($conn2))->ringUp(new SaleRequest(
        lines: [new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '5.00', inventoryItemId: 'i')],
        tenders: [new TenderInput('cash', '5.00')],
        idempotencyKey: 'explicit-key',
    ));
    $t->assertSame('explicit-key', $conn2->findCall('post_sale(')['params']['key'], 'an explicit key is used verbatim');

    // Without a sale date, today's date is used.
    $conn3 = new FakeConnection();
    $conn3->on('INSERT INTO sale_line', static fn () => null);
    $conn3->on('INSERT INTO sale', static fn () => [['id' => 'sale-3', 'sale_no' => '1003']]);
    $conn3->on('INSERT INTO payment_tender', static fn () => null);
    $conn3->on('INSERT INTO payment', static fn () => [['id' => 'pay-3']]);
    $conn3->on('post_sale_inventory', static fn () => 1);
    $conn3->on('post_sale(', static fn () => 'entry-3');

    (new PosService($conn3))->ringUp(new SaleRequest(
        lines: [new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '5.00', inventoryItemId: 'i')],
        tenders: [new TenderInput('cash', '5.00')],
    ));
    $t->assertSame(date('Y-m-d'), $conn3->findCall('post_sale(')['params']['date'], 'ringUp defaults the date to today');

    // The derived key is stable: the same request yields the same key.
    $conn4 = new FakeConnection();
    $conn4->on('INSERT INTO sale_line', static fn () => null);
    $conn4->on('INSERT INTO sale', static fn () => [['id' => 'sale-4', 'sale_no' => '1004']]);
    $conn4->on('INSERT INTO payment_tender', static fn () => null);
    $conn4->on('INSERT INTO payment', static fn () => [['id' => 'pay-4']]);
    $conn4->on('post_sale_inventory', static fn () => 1);
    $conn4->on('post_sale(', static fn () => 'entry-4');

    (new PosService($conn4))->ringUp($request);
    $t->assertSame($expectedKey, $conn4->findCall('post_sale(')['params']['key'], 'the derived key is deterministic');

    // A different request yields a different key.
    $conn5 = new FakeConnection();
    $conn5->on('INSERT INTO sale_line', static fn () => null);
    $conn5->on('INSERT INTO sale', static fn () => [['id' => 'sale-5', 'sale_no' => '1005']]);
    $conn5->on('INSERT INTO payment_tender', static fn () => null);
    $conn5->on('INSERT INTO payment', static fn () => [['id' => 'pay-5']]);
    $conn5->on('post_sale_inventory', static fn () => 1);
    $conn5->on('post_sale(', static fn () => 'entry-5');

    (new PosService($conn5))->ringUp(new SaleRequest(
        lines: [new SaleLineInput(SaleLineInput::OWNED, 'Widget', '3', '10.00', inventoryItemId: 'inv-1')],
        tenders: [new TenderInput('cash', '30.00')],
        registerId: 'reg-1',
        shiftId: 'shift-1',
        saleDate: '2026-03-15',
    ));
    $t->assertTrue(
        $conn5->findCall('post_sale(')['params']['key'] !== $expectedKey,
        'a different quantity yields a different key',
    );

    // refund derives 'refund:{sale}:{date}' when no key is given.
    $rConn = new FakeConnection();
    $rConn->on('INSERT INTO sale_line', static fn () => null);
    $rConn->on('INSERT INTO sale', static fn () => [['id' => 'refund-1', 'sale_no' => 'R-1']]);
    $rConn->on('INSERT INTO payment_tender', static fn () => null);
    $rConn->on('INSERT INTO payment', static fn () => [['id' => 'pay-r']]);
    $rConn->on('post_refund_inventory', static fn () => 1);
    $rConn->on('post_refund(', static fn () => 'refund-entry');

    (new PosService($rConn))->refund(
        'sale-1',
        [new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '10.00', inventoryItemId: 'i')],
        [new TenderInput('cash', '10.00')],
        'USD',
        '2026-04-01',
    );
    $t->assertSame('refund:sale-1:2026-04-01', $rConn->findCall('post_refund(')['params']['key'], 'refund derives its key');

    // closeShift derives 'shift_close:{shift}:{date}'.
    $sConn = new FakeConnection();
    $sConn->on('post_shift_close', static fn () => 'close-entry');
    (new PosService($sConn))->closeShift('shift-9', '100.00', '2026-04-02');
    $t->assertSame('shift_close:shift-9:2026-04-02', $sConn->findCall('post_shift_close')['params']['key'], 'closeShift derives its key');

    // settleMerchant derives 'merchant_settlement:{id}'.
    $mConn = new FakeConnection();
    $mConn->on('INSERT INTO merchant_settlement', static fn () => [['id' => 'ms-7']]);
    $mConn->on('post_merchant_settlement', static fn () => 'ms-entry');
    (new PosService($mConn))->settleMerchant('100.00', '2.50');
    $t->assertSame('merchant_settlement:ms-7', $mConn->findCall('post_merchant_settlement')['params']['key'], 'settleMerchant derives its key');
};
