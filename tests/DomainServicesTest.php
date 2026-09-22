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
use NinjaEMP\Money\Allocator;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;
use NinjaEMP\Tests\Support\FakeConnection;

require_once __DIR__ . '/Support/FakeConnection.php';

/**
 * Domain-service tests. These exercise the orchestration — the SQL issued, the
 * money computed, the posting functions called — against a fake Connection, so
 * they run without a live PostgreSQL.
 */
return static function (TestHarness $t): void {
    $usd = Currency::of('USD');

    // ---- Allocator (ADR-0009) --------------------------------------------

    $t->suite('Allocator');

    $parts = Allocator::allocate(Money::of('10.00', $usd), ['1', '1', '1']);
    $t->assertSame('3.3334', $parts[0]->amount(), 'largest remainder: first part gets the extra unit');
    $t->assertSame('3.3333', $parts[1]->amount(), 'largest remainder: second part');
    $t->assertSame('3.3333', $parts[2]->amount(), 'largest remainder: third part');
    $sum = Money::zero($usd);

    foreach ($parts as $p) {
        $sum = $sum->plus($p);
    }
    $t->assertSame('10.0000', $sum->amount(), 'allocated parts sum exactly to the whole');

    $parts = Allocator::allocate(Money::of('100.00', $usd), ['0.6', '0.4']);
    $t->assertSame('60.0000', $parts[0]->amount(), 'rate split: 60%');
    $t->assertSame('40.0000', $parts[1]->amount(), 'rate split: 40%');

    $parts = Allocator::allocate(Money::of('0.05', $usd), ['1', '1', '1']);
    $t->assertSame('0.0167', $parts[0]->amount(), 'tiny split: first unit');
    $t->assertSame('0.0167', $parts[1]->amount(), 'tiny split: second unit');
    $t->assertSame('0.0166', $parts[2]->amount(), 'tiny split: third unit');
    $t->assertSame('0.0500', $parts[0]->plus($parts[1])->plus($parts[2])->amount(), 'tiny split sums exactly');

    $t->assertThrows(InvalidArgumentException::class, fn () => Allocator::allocate(Money::of('1.00', $usd), []), 'empty weights rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => Allocator::allocate(Money::of('1.00', $usd), ['0', '0']), 'zero weight sum rejected');

    // ---- PosService -------------------------------------------------------

    $t->suite('PosService');

    $conn = new FakeConnection();
    $conn->on('INSERT INTO sale_line', static fn () => null);
    $conn->on('INSERT INTO sale', static fn () => [['id' => 'sale-1', 'sale_no' => '1001']]);
    $conn->on('INSERT INTO payment_tender', static fn () => null);
    $conn->on('INSERT INTO payment', static fn () => [['id' => 'pay-1']]);
    $conn->on('post_sale_inventory', static fn () => 2);
    $conn->on('post_sale(', static fn () => 'entry-1');

    $pos = new PosService($conn);
    $result = $pos->ringUp(new SaleRequest(
        lines: [
            new SaleLineInput(
                kind: SaleLineInput::CONSIGNMENT,
                description: 'Vintage lamp',
                quantity: '2',
                unitPrice: '25.00',
                commissionRate: '0.40',
                consignorPartyId: 'consignor-1',
                consignmentItemId: 'ci-1',
                sku: 'LAMP-1',
            ),
        ],
        tenders: [new TenderInput('cash', '50.00')],
        registerId: 'reg-1',
        shiftId: 'shift-1',
    ));

    $t->assertSame('50.0000', $result->subtotal, 'POS subtotal = qty * price');
    $t->assertSame('0.0000', $result->discountTotal, 'POS discount total');
    $t->assertSame('0.0000', $result->taxTotal, 'POS tax total');
    $t->assertSame('50.0000', $result->total, 'POS total');
    $t->assertSame('entry-1', $result->journalEntryId, 'POS returns the ledger entry id');
    $t->assertSame(2, $result->inventoryLinesRelieved, 'POS reports relieved inventory lines');
    $t->assertSame(1, $conn->transactionCount, 'POS runs in one transaction');
    $t->assertTrue($conn->calledWith('post_sale('), 'POS delegates posting to post_sale()');
    $t->assertTrue($conn->calledWith('post_sale_inventory'), 'POS relieves inventory via post_sale_inventory()');

    // The commission split must be exact: commission + net = extended price.
    $lineCall = $conn->findCall('INSERT INTO sale_line');
    $t->assertTrue($lineCall !== null, 'POS inserts sale lines');
    $t->assertSame('20.0000', $lineCall['params']['commission_amount'], 'commission = extended * rate');
    $t->assertSame('30.0000', $lineCall['params']['net'], 'net = extended - commission (exact remainder)');
    $t->assertSame('50.0000', $lineCall['params']['extended'], 'extended price');

    // Tender mismatch is refused before anything is written.
    $conn2 = new FakeConnection();
    $conn2->on('INSERT INTO sale_line', static fn () => null);
    $conn2->on('INSERT INTO sale', static fn () => [['id' => 'sale-2', 'sale_no' => '1002']]);
    $pos2 = new PosService($conn2);
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $pos2->ringUp(new SaleRequest(
            lines: [new SaleLineInput(SaleLineInput::OWNED, 'Widget', '1', '10.00', inventoryItemId: 'inv-1')],
            tenders: [new TenderInput('cash', '9.00')],
        )),
        'tenders that do not cover the total are rejected',
    );

    // A liability tender without a party is rejected at construction.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => new TenderInput('store_credit', '5.00'),
        'liability tender requires a party id',
    );

    // ---- InventoryService -------------------------------------------------

    $t->suite('InventoryService');

    $conn3 = new FakeConnection();
    $conn3->on('INSERT INTO inventory_item', static fn () => [['id' => 'inv-9']]);
    $conn3->on('receive_inventory', static fn () => 'recv-entry');
    $conn3->on('adjust_inventory', static fn () => 'adj-entry');

    $inv = new InventoryService($conn3);
    $itemId = $inv->createItem('SKU-9', 'Widget', '19.99', 'USD', 'gadgets', 'supplier-1', 'each', '0123456789012');
    $t->assertSame('inv-9', $itemId, 'createItem returns the new id');

    $entry = $inv->receive('inv-9', '10', '5.00', true);
    $t->assertSame('recv-entry', $entry, 'receive returns the receipt entry id');
    $recvCall = $conn3->findCall('receive_inventory');
    $t->assertSame('10', $recvCall['params']['qty'], 'receive passes the quantity');
    $t->assertSame('5.00', $recvCall['params']['cost'], 'receive passes the unit cost');
    $t->assertSame('true', $recvCall['params']['on_account'], 'receive passes on_account');

    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $inv->receive('inv-9', '0', '5.00'),
        'receive rejects a non-positive quantity',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $inv->receive('inv-9', '1', '-1.00'),
        'receive rejects a negative unit cost',
    );

    $adj = $inv->adjust('inv-9', '-3', 'Shrink');
    $t->assertSame('adj-entry', $adj, 'adjust returns the adjustment entry id');
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $inv->adjust('inv-9', '0'),
        'adjust rejects a zero delta',
    );

    // ---- ConsignmentService ----------------------------------------------

    $t->suite('ConsignmentService');

    $conn4 = new FakeConnection();
    $conn4->on('INSERT INTO consignor_agreement', static fn () => [['id' => 'agr-1']]);
    $conn4->on('INSERT INTO consignment_item', static fn () => [['id' => 'ci-1']]);
    $conn4->on('INSERT INTO consignment_sale_line', static fn () => null);
    $conn4->on('INSERT INTO consignment_sale', static fn () => [['id' => 'cs-1', 'sale_no' => '5001']]);
    $conn4->on('UPDATE consignment_item', static fn () => null);
    $conn4->on('post_consignment_sale', static fn () => 'cs-entry');

    $cons = new ConsignmentService($conn4);
    $agrId = $cons->createAgreement('consignor-1', '0.40');
    $t->assertSame('agr-1', $agrId, 'createAgreement returns the agreement id');

    $sale = $cons->recordSale([
        ['itemId' => 'ci-1', 'consignorPartyId' => 'consignor-1', 'salePrice' => '100.00', 'commissionRate' => '0.40'],
    ]);
    $t->assertSame('cs-1', $sale['saleId'], 'recordSale returns the sale id');
    $t->assertSame('100.0000', $sale['gross'], 'recordSale gross');
    $t->assertSame('60.0000', $sale['net'], 'recordSale net to consignor');
    $t->assertSame('cs-entry', $sale['journalEntryId'], 'recordSale posts via post_consignment_sale');

    $lineCall = $conn4->findCall('INSERT INTO consignment_sale_line');
    $t->assertSame('40.0000', $lineCall['params']['commission'], 'consignment commission = price * rate');
    $t->assertSame('60.0000', $lineCall['params']['net'], 'consignment net = price - commission (exact)');

    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $cons->createAgreement('consignor-1', '1.50'),
        'commission rate above 1 is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $cons->recordSale([]),
        'an empty consignment sale is rejected',
    );

    // ---- VendorMallService ------------------------------------------------

    $t->suite('VendorMallService');

    $conn5 = new FakeConnection();
    $conn5->on('INSERT INTO lease_deposit', static fn () => [['id' => 'dep-1']]);
    $conn5->on('INSERT INTO lease', static fn () => [['id' => 'lease-1']]);
    $conn5->on('INSERT INTO rent_component', static fn () => [['id' => 'rc-1']]);
    $conn5->on('INSERT INTO lease_space', static fn () => null);
    $conn5->on('UPDATE lease_space', static fn () => null);
    $conn5->on('UPDATE space', static fn () => null);
    $conn5->on('post_rent_invoice', static fn () => 'rent-entry');
    $conn5->on('post_deposit_receipt', static fn () => 'dep-entry');

    $mall = new VendorMallService($conn5);
    $leaseId = $mall->createLease('vendor-1', 'loc-1', '2026-01-01', null, 5);
    $t->assertSame('lease-1', $leaseId, 'createLease returns the lease id');

    $mall->allocateSpace('lease-1', 'space-1', '2026-01-01');
    $t->assertTrue($conn5->calledWith('UPDATE lease_space'), 'allocateSpace ends the prior allocation');
    $t->assertTrue($conn5->calledWith('UPDATE space'), 'allocateSpace marks the space leased');

    $rcId = $mall->addRentComponent('lease-1', 'base_rent', '1200.00');
    $t->assertSame('rc-1', $rcId, 'addRentComponent returns the component id');
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $mall->addRentComponent('lease-1', 'percentage_rent', '0'),
        'percentage rent without a rate is rejected',
    );

    $rentEntry = $mall->billRent('lease-1', '2026-01-01', '2026-01-31');
    $t->assertSame('rent-entry', $rentEntry, 'billRent posts via post_rent_invoice');
    $rentCall = $conn5->findCall('post_rent_invoice');
    $t->assertSame('lease-1', $rentCall['params']['lease'], 'billRent passes the lease id');

    $depEntry = $mall->recordDeposit('lease-1', '500.00');
    $t->assertSame('dep-entry', $depEntry, 'recordDeposit posts via post_deposit_receipt');
};
