<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use InvalidArgumentException;
use NinjaEMP\Domain\Consignment\ConsignmentService;
use NinjaEMP\Domain\Inventory\InventoryService;
use NinjaEMP\Domain\Pos\PosService;
use NinjaEMP\Domain\Pos\SaleLineInput;
use NinjaEMP\Domain\Pos\SaleRequest;
use NinjaEMP\Domain\Pos\TenderInput;
use NinjaEMP\Domain\VendorMall\VendorMallService;
use NinjaEMP\Tests\Support\FakeConnection;

require_once __DIR__ . '/Support/FakeConnection.php';

/**
 * Mutation-hardening tests for the POS and consignment domain services.
 *
 * These pin the exact money arithmetic (discounts, tax, commission remainders),
 * the boundary conditions of the validation guards, and the exact posting
 * function each path delegates to.
 */
return static function (TestHarness $t): void {
    // ---- PosService ---------------------------------------------------------

    $t->suite('PosService (hardening)');

    $conn = new FakeConnection();
    $conn->on('INSERT INTO sale_line', static fn () => null);
    $conn->on('INSERT INTO sale', static fn () => [['id' => 'sale-1', 'sale_no' => '1001']]);
    $conn->on('INSERT INTO payment_tender', static fn () => null);
    $conn->on('INSERT INTO payment', static fn () => [['id' => 'pay-1']]);
    $conn->on('post_sale_inventory', static fn () => 3);
    $conn->on('post_sale(', static fn () => 'entry-1');

    $pos = new PosService($conn);

    // A sale with a discount and tax: total = subtotal - discount + tax.
    $result = $pos->ringUp(new SaleRequest(
        lines: [
            new SaleLineInput(
                kind: SaleLineInput::OWNED,
                description: 'Widget',
                quantity: '2',
                unitPrice: '10.00',
                discountAmount: '5.00',
                taxAmount: '1.00',
                inventoryItemId: 'inv-1',
            ),
        ],
        tenders: [new TenderInput('cash', '16.00')],
    ));

    $t->assertSame('20.0000', $result->subtotal, 'subtotal = qty * unit price');
    $t->assertSame('5.0000', $result->discountTotal, 'discount total');
    $t->assertSame('1.0000', $result->taxTotal, 'tax total');
    $t->assertSame('16.0000', $result->total, 'total = subtotal - discount + tax');
    $t->assertSame(3, $result->inventoryLinesRelieved, 'relieved line count is passed through');

    // A line discount larger than the extended price is refused.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $pos->ringUp(new SaleRequest(
            lines: [new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '10.00', discountAmount: '11.00', inventoryItemId: 'i')],
            tenders: [new TenderInput('cash', '0.00')],
        )),
        'a line discount cannot exceed the extended price',
    );

    // Two lines: totals accumulate across lines.
    $conn2 = new FakeConnection();
    $conn2->on('INSERT INTO sale_line', static fn () => null);
    $conn2->on('INSERT INTO sale', static fn () => [['id' => 'sale-2', 'sale_no' => '1002']]);
    $conn2->on('INSERT INTO payment_tender', static fn () => null);
    $conn2->on('INSERT INTO payment', static fn () => [['id' => 'pay-2']]);
    $conn2->on('post_sale_inventory', static fn () => 2);
    $conn2->on('post_sale(', static fn () => 'entry-2');

    $result = (new PosService($conn2))->ringUp(new SaleRequest(
        lines: [
            new SaleLineInput(SaleLineInput::OWNED, 'A', '1', '10.00', inventoryItemId: 'i1'),
            new SaleLineInput(SaleLineInput::OWNED, 'B', '3', '5.00', inventoryItemId: 'i2'),
        ],
        tenders: [new TenderInput('cash', '25.00')],
    ));
    $t->assertSame('25.0000', $result->subtotal, 'subtotal accumulates across lines');
    $t->assertSame('25.0000', $result->total, 'total accumulates across lines');

    // Refund posts through post_refund / post_refund_inventory.
    $conn3 = new FakeConnection();
    $conn3->on('INSERT INTO sale_line', static fn () => null);
    $conn3->on('INSERT INTO sale', static fn () => [['id' => 'refund-1', 'sale_no' => 'R-1']]);
    $conn3->on('INSERT INTO payment_tender', static fn () => null);
    $conn3->on('INSERT INTO payment', static fn () => [['id' => 'pay-3']]);
    $conn3->on('post_refund_inventory', static fn () => 1);
    $conn3->on('post_refund(', static fn () => 'refund-entry');

    $refund = (new PosService($conn3))->refund(
        'sale-1',
        [new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '10.00', inventoryItemId: 'i')],
        [new TenderInput('cash', '10.00')],
    );
    $t->assertSame('refund-1', $refund->saleId, 'refund returns its own document id');
    $t->assertSame('10.0000', $refund->total, 'refund total');
    $t->assertSame('refund-entry', $refund->journalEntryId, 'refund posts via post_refund()');
    $t->assertTrue($conn3->calledWith('post_refund('), 'refund delegates to post_refund()');

    // openShift returns the shift id.
    $conn4 = new FakeConnection();
    $conn4->on('INSERT INTO shift', static fn () => [['id' => 'shift-1']]);
    $t->assertSame('shift-1', (new PosService($conn4))->openShift('reg-1', '100.00'), 'openShift returns the shift id');

    // closeShift returns the over/short entry id, or null when balanced.
    $conn5 = new FakeConnection();
    $conn5->on('post_shift_close', static fn () => 'close-entry');
    $t->assertSame('close-entry', (new PosService($conn5))->closeShift('shift-1', '100.00'), 'closeShift returns the entry id');

    $conn6 = new FakeConnection();
    $conn6->on('post_shift_close', static fn () => null);
    $t->assertSame(null, (new PosService($conn6))->closeShift('shift-1', '100.00'), 'closeShift returns null when balanced');

    // settleMerchant computes net = gross - fee and posts the settlement.
    $conn7 = new FakeConnection();
    $conn7->on('INSERT INTO merchant_settlement', static fn () => [['id' => 'ms-1']]);
    $conn7->on('post_merchant_settlement', static fn () => 'ms-entry');
    $t->assertSame('ms-entry', (new PosService($conn7))->settleMerchant('100.00', '2.50'), 'settleMerchant returns the entry id');
    $msCall = $conn7->findCall('INSERT INTO merchant_settlement');
    $t->assertTrue($msCall !== null, 'settleMerchant inserts the settlement');
    $t->assertSame('100.0000', $msCall['params']['gross'], 'settlement gross');
    $t->assertSame('2.5000', $msCall['params']['fee'], 'settlement fee');
    $t->assertSame('97.5000', $msCall['params']['net'], 'settlement net = gross - fee');

    // ---- ConsignmentService -------------------------------------------------

    $t->suite('ConsignmentService (hardening)');

    $cConn = new FakeConnection();
    $cConn->on('INSERT INTO consignor_agreement', static fn () => [['id' => 'agr-1']]);
    $cons = new ConsignmentService($cConn);

    // Commission-rate boundaries: 0 and 1 are allowed, outside is not.
    $t->assertSame('agr-1', $cons->createAgreement('c1', '0'), 'a 0% commission rate is allowed');
    $t->assertSame('agr-1', $cons->createAgreement('c1', '1'), 'a 100% commission rate is allowed');
    $t->assertThrows(InvalidArgumentException::class, fn () => $cons->createAgreement('c1', '-0.01'), 'a negative rate is rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $cons->createAgreement('c1', '1.01'), 'a rate above 1 is rejected');

    // Every documented settlement frequency is accepted.
    foreach (['on_demand', 'weekly', 'biweekly', 'monthly'] as $freq) {
        $t->assertSame('agr-1', $cons->createAgreement('c1', '0.4', $freq), "frequency {$freq} is accepted");
    }

    // recordSale sums gross and net across lines with exact commission splits.
    $sConn = new FakeConnection();
    $sConn->on('INSERT INTO consignment_sale_line', static fn () => null);
    $sConn->on('UPDATE consignment_item SET status', static fn () => null);
    $sConn->on('INSERT INTO consignment_sale', static fn () => [['id' => 'cs-1', 'sale_no' => 'CS-1']]);
    $sConn->on('post_consignment_sale', static fn () => 'cs-entry');

    $sale = (new ConsignmentService($sConn))->recordSale([
        ['itemId' => 'i1', 'consignorPartyId' => 'c1', 'salePrice' => '100.00', 'commissionRate' => '0.40'],
        ['itemId' => 'i2', 'consignorPartyId' => 'c1', 'salePrice' => '50.00', 'commissionRate' => '0.20'],
    ]);
    $t->assertSame('150.0000', $sale['gross'], 'recordSale gross sums lines');
    $t->assertSame('100.0000', $sale['net'], 'recordSale net sums remainders (60 + 40)');
    $t->assertSame('cs-entry', $sale['journalEntryId'], 'recordSale posts via post_consignment_sale()');
    $t->assertThrows(InvalidArgumentException::class, fn () => (new ConsignmentService(new FakeConnection()))->recordSale([]), 'recordSale needs a line');

    // settleAndPay sums the sold lines and pays the net.
    $pConn = new FakeConnection();
    $pConn->on('INSERT INTO settlement_line', static fn () => null);
    $pConn->on('FROM consignment_sale_line csl', static fn () => [
        ['id' => 'l1', 'sale_price' => '100.00', 'commission_amount' => '40.00', 'net_to_consignor' => '60.00'],
        ['id' => 'l2', 'sale_price' => '50.00', 'commission_amount' => '10.00', 'net_to_consignor' => '40.00'],
    ]);
    $pConn->on('INSERT INTO consignor_settlement', static fn () => [['id' => 'set-1']]);
    $pConn->on('INSERT INTO consignor_payout', static fn () => [['id' => 'payout-1']]);
    $pConn->on('post_consignor_payout', static fn () => 'payout-entry');

    $settlement = (new ConsignmentService($pConn))->settleAndPay('c1', '2026-01-01', '2026-01-31');
    $t->assertSame('set-1', $settlement['settlementId'], 'settleAndPay settlement id');
    $t->assertSame('payout-1', $settlement['payoutId'], 'settleAndPay payout id');
    $t->assertSame('100.0000', $settlement['netPayable'], 'settleAndPay net = 60 + 40');
    $t->assertSame('payout-entry', $settlement['journalEntryId'], 'settleAndPay posts via post_consignor_payout()');

    // ---- VendorMallService --------------------------------------------------

    $t->suite('VendorMallService (hardening)');

    $vConn = new FakeConnection();
    $vConn->on('INSERT INTO lease_space', static fn () => null);
    $vConn->on('UPDATE lease_space', static fn () => null);
    $vConn->on('UPDATE space SET status', static fn () => null);
    $vConn->on('INSERT INTO lease', static fn () => [['id' => 'lease-1']]);
    $vConn->on('INSERT INTO rent_component', static fn () => [['id' => 'rc-1']]);
    $vConn->on('post_rent_invoice', static fn () => 'rent-entry');
    $vConn->on('INSERT INTO lease_deposit', static fn () => [['id' => 'dep-1']]);
    $vConn->on('post_deposit_receipt', static fn () => 'dep-entry');
    $vm = new VendorMallService($vConn);

    // Billing-day boundaries: 1 and 28 are allowed, 0 and 29 are not.
    $t->assertSame('lease-1', $vm->createLease('v1', 'loc-1', billingDay: 1), 'billing day 1 is allowed');
    $t->assertSame('lease-1', $vm->createLease('v1', 'loc-1', billingDay: 28), 'billing day 28 is allowed');
    $t->assertThrows(InvalidArgumentException::class, fn () => $vm->createLease('v1', 'loc-1', billingDay: 0), 'billing day 0 is rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $vm->createLease('v1', 'loc-1', billingDay: 29), 'billing day 29 is rejected');

    // allocateSpace ends the current allocation, opens a new one, and marks the space leased.
    $vm->allocateSpace('lease-1', 'space-1', '2026-02-01');
    $t->assertTrue($vConn->calledWith('UPDATE lease_space SET thru_date'), 'allocateSpace ends the prior allocation');
    $t->assertTrue($vConn->calledWith('INSERT INTO lease_space'), 'allocateSpace opens the new allocation');
    $t->assertTrue($vConn->calledWith("UPDATE space SET status = 'leased'"), 'allocateSpace marks the space leased');

    // Rent components: frequency and percentage-rent guards.
    $t->assertSame('rc-1', $vm->addRentComponent('lease-1', 'base_rent', '1000.00'), 'addRentComponent returns the id');

    foreach (['monthly', 'quarterly', 'annual'] as $freq) {
        $t->assertSame('rc-1', $vm->addRentComponent('lease-1', 'base_rent', '1', 'USD', null, null, $freq), "frequency {$freq} is accepted");
    }
    $t->assertThrows(InvalidArgumentException::class, fn () => $vm->addRentComponent('lease-1', 'base_rent', '1', 'USD', null, null, 'hourly'), 'unknown frequency is rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $vm->addRentComponent('lease-1', 'percentage_rent'), 'percentage rent needs a rate');
    $t->assertSame('rc-1', $vm->addRentComponent('lease-1', 'percentage_rent', '0', 'USD', '0.05'), 'percentage rent with a rate is accepted');

    // billRent and recordDeposit delegate to their posting functions.
    $t->assertSame('rent-entry', $vm->billRent('lease-1', '2026-01-01', '2026-01-31'), 'billRent returns the entry id');
    $t->assertSame('dep-entry', $vm->recordDeposit('lease-1', '500.00'), 'recordDeposit returns the entry id');

    // ---- InventoryService ---------------------------------------------------

    $t->suite('InventoryService (hardening)');

    $iConn = new FakeConnection();
    $iConn->on('INSERT INTO inventory_item', static fn () => [['id' => 'inv-1']]);
    $iConn->on('receive_inventory', static fn () => 'recv-entry');
    $iConn->on('adjust_inventory', static fn () => 'adj-entry');
    $iConn->on('SELECT on_hand, avg_cost, currency FROM inventory_item', static fn () => [['on_hand' => '5', 'avg_cost' => '2.0000', 'currency' => 'USD']]);
    $iConn->on('COALESCE(sum(on_hand * avg_cost)', static fn () => '10.0000');
    $inv = new InventoryService($iConn);

    $t->assertSame('inv-1', $inv->createItem('SKU-1', 'Widget', '9.99'), 'createItem returns the id');
    $t->assertSame('recv-entry', $inv->receive('inv-1', '10', '2.00'), 'receive returns the entry id');
    $t->assertSame('adj-entry', $inv->adjust('inv-1', '-1', 'shrink'), 'adjust returns the entry id');

    // Receipt guards: quantity must be positive, cost non-negative.
    $t->assertThrows(InvalidArgumentException::class, fn () => $inv->receive('inv-1', '0', '2.00'), 'a zero receipt quantity is rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $inv->receive('inv-1', '-1', '2.00'), 'a negative receipt quantity is rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $inv->receive('inv-1', '1', '-0.01'), 'a negative unit cost is rejected');
    $t->assertSame('recv-entry', $inv->receive('inv-1', '1', '0'), 'a zero unit cost is allowed');

    // Adjustment guard: the delta cannot be zero.
    $t->assertThrows(InvalidArgumentException::class, fn () => $inv->adjust('inv-1', '0'), 'a zero adjustment is rejected');

    // position returns the exact on-hand / average cost / currency.
    $position = $inv->position('inv-1');
    $t->assertSame('5', $position['on_hand'], 'position on_hand');
    $t->assertSame('2.0000', $position['avg_cost'], 'position avg_cost');
    $t->assertSame('USD', $position['currency'], 'position currency');
    $t->assertThrows(InvalidArgumentException::class, fn () => (new InventoryService(new FakeConnection()))->position('missing'), 'position rejects a missing item');

    // totalValue returns a scale-4 money string.
    $t->assertSame('10.0000', $inv->totalValue(), 'totalValue returns the summed value');
};
