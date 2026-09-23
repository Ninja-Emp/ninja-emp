<?php

declare(strict_types=1);

/**
 * Consignment + vendor-mall parameter-binding hardening.
 *
 * The domain services are thin orchestrators over SQL. Mutation testing showed
 * the surviving mutants were almost entirely ArrayItemRemoval inside the bound
 * parameter arrays \u2014 a dropped key silently binds NULL. These tests assert the
 * exact parameter map for every statement each service issues, so a dropped or
 * renamed key is caught.
 */

use NinjaEMP\Domain\Consignment\ConsignmentService;
use NinjaEMP\Domain\VendorMall\VendorMallService;
use NinjaEMP\Tests\Support\FakeConnection;
use NinjaEMP\Tests\TestHarness;

require_once __DIR__ . '/Support/FakeConnection.php';

return static function (TestHarness $t): void {
    // ---- ConsignmentService: createAgreement ------------------------------
    $t->suite('ConsignmentService (params)');

    $conn = new FakeConnection();
    $conn->on('INSERT INTO consignor_agreement', static fn () => [['id' => 'agr-1']]);
    $cons = new ConsignmentService($conn);

    $cons->createAgreement('party-9', '0.35', 'weekly', '2026-02-01', 'note');
    $call = $conn->findCall('INSERT INTO consignor_agreement');
    $t->assertSame(
        ['party' => 'party-9', 'rate' => '0.35', 'freq' => 'weekly', 'start' => '2026-02-01', 'notes' => 'note'],
        $call['params'],
        'createAgreement binds every column',
    );

    // ---- receiveItem ------------------------------------------------------
    $conn->on('INSERT INTO consignment_item', static fn () => [['id' => 'ci-1']]);
    $cons->receiveItem('agr-1', 'A lamp', '25.00', 'EUR', 'SKU-1', 'lighting', 'good', 'BC-1', '2026-02-02');
    $call = $conn->findCall('INSERT INTO consignment_item');
    $t->assertSame(
        [
            'agreement' => 'agr-1',
            'sku' => 'SKU-1',
            'description' => 'A lamp',
            'category' => 'lighting',
            'condition' => 'good',
            'price' => '25.00',
            'currency' => 'EUR',
            'barcode' => 'BC-1',
            'received' => '2026-02-02',
        ],
        $call['params'],
        'receiveItem binds every column',
    );

    // ---- changePrice ------------------------------------------------------
    $conn->on('SELECT agreed_price FROM consignment_item', static fn () => [['agreed_price' => '10.00']]);
    $conn->on('INSERT INTO item_price_change', static fn () => null);
    $conn->on('UPDATE consignment_item SET agreed_price', static fn () => null);

    $cons->changePrice('ci-1', '12.00', 'seasonal');
    $change = $conn->findCall('INSERT INTO item_price_change');
    $t->assertSame(
        ['item' => 'ci-1', 'old' => '10.00', 'new' => '12.00', 'reason' => 'seasonal'],
        $change['params'],
        'changePrice records the old and new price',
    );
    $update = $conn->findCall('UPDATE consignment_item SET agreed_price');
    $t->assertSame(['price' => '12.00', 'id' => 'ci-1'], $update['params'], 'changePrice updates the item price');

    // A missing item is rejected before any write.
    $missing = new FakeConnection();
    $missing->on('SELECT agreed_price FROM consignment_item', static fn () => null);
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new ConsignmentService($missing))->changePrice('nope', '1.00'),
        'changePrice rejects an unknown item',
    );

    // ---- recordSale -------------------------------------------------------
    $sale = new FakeConnection();
    $sale->on('INSERT INTO consignment_sale_line', static fn () => null);
    $sale->on('INSERT INTO consignment_sale (', static fn () => [['id' => 'cs-1', 'sale_no' => 'CS-1']]);
    $sale->on('UPDATE consignment_item SET status', static fn () => null);
    $sale->on('post_consignment_sale', static fn () => 'entry-1');

    $result = (new ConsignmentService($sale))->recordSale(
        [['itemId' => 'i1', 'consignorPartyId' => 'c1', 'salePrice' => '100.00', 'commissionRate' => '0.40']],
        'USD',
        'cust-1',
        'online',
        '2026-03-01',
    );

    $saleCall = $sale->findCall('INSERT INTO consignment_sale (');
    $t->assertSame(
        ['date' => '2026-03-01', 'channel' => 'online', 'customer' => 'cust-1'],
        $saleCall['params'],
        'recordSale binds the sale header',
    );

    $lineCall = $sale->findCall('INSERT INTO consignment_sale_line');
    $t->assertSame(
        [
            'sale' => 'cs-1',
            'item' => 'i1',
            'consignor' => 'c1',
            'price' => '100.0000',
            'rate' => '0.40',
            'commission' => '40.0000',
            'net' => '60.0000',
            'currency' => 'USD',
        ],
        $lineCall['params'],
        'recordSale binds every sale-line column',
    );

    $soldCall = $sale->findCall('UPDATE consignment_item SET status');
    $t->assertSame(['id' => 'i1'], $soldCall['params'], 'recordSale marks the item sold');

    $postCall = $sale->findCall('post_consignment_sale');
    $t->assertSame(
        ['sale' => 'cs-1', 'date' => '2026-03-01', 'key' => 'consignment_sale:cs-1'],
        $postCall['params'],
        'recordSale derives the idempotency key from the sale id',
    );

    // An explicit idempotency key overrides the derived one.
    $sale2 = new FakeConnection();
    $sale2->on('INSERT INTO consignment_sale_line', static fn () => null);
    $sale2->on('INSERT INTO consignment_sale (', static fn () => [['id' => 'cs-2', 'sale_no' => 'CS-2']]);
    $sale2->on('UPDATE consignment_item SET status', static fn () => null);
    $sale2->on('post_consignment_sale', static fn () => 'entry-2');
    (new ConsignmentService($sale2))->recordSale(
        [['itemId' => 'i1', 'consignorPartyId' => 'c1', 'salePrice' => '10.00', 'commissionRate' => '0.10']],
        idempotencyKey: 'my-key',
    );
    $t->assertSame('my-key', $sale2->findCall('post_consignment_sale')['params']['key'], 'explicit idempotency key wins');

    // ---- settleAndPay -----------------------------------------------------
    $pay = new FakeConnection();
    $pay->on('FROM consignment_sale_line csl', static fn () => [
        ['id' => 'l1', 'sale_price' => '100.00', 'commission_amount' => '40.00', 'net_to_consignor' => '60.00'],
    ]);
    $pay->on('INSERT INTO consignor_settlement', static fn () => [['id' => 'set-1']]);
    $pay->on('INSERT INTO settlement_line', static fn () => null);
    $pay->on('INSERT INTO consignor_payout', static fn () => [['id' => 'payout-1']]);
    $pay->on('post_consignor_payout', static fn () => 'entry-3');

    $settlement = (new ConsignmentService($pay))->settleAndPay('c1', '2026-01-01', '2026-01-31', 'USD', 'ach', '2026-02-05');

    $setCall = $pay->findCall('INSERT INTO consignor_settlement');
    $t->assertSame(
        [
            'party' => 'c1',
            'start' => '2026-01-01',
            'end' => '2026-01-31',
            'gross' => '100.0000',
            'commission' => '40.0000',
            'net' => '60.0000',
            'currency' => 'USD',
        ],
        $setCall['params'],
        'settleAndPay binds the settlement totals',
    );

    $lineCall = $pay->findCall('INSERT INTO settlement_line');
    $t->assertSame(
        ['settlement' => 'set-1', 'sale_line' => 'l1', 'gross' => '100.0000', 'commission' => '40.0000', 'net' => '60.0000'],
        $lineCall['params'],
        'settleAndPay binds each settlement line',
    );

    $payoutCall = $pay->findCall('INSERT INTO consignor_payout');
    $t->assertSame(
        ['settlement' => 'set-1', 'amount' => '60.0000', 'currency' => 'USD', 'date' => '2026-02-05', 'method' => 'ach'],
        $payoutCall['params'],
        'settleAndPay binds the payout',
    );

    $postPayout = $pay->findCall('post_consignor_payout');
    $t->assertSame(
        ['payout' => 'payout-1', 'date' => '2026-02-05', 'key' => 'consignor_payout:payout-1'],
        $postPayout['params'],
        'settleAndPay derives the payout idempotency key',
    );

    // No sold lines in the period is rejected.
    $empty = new FakeConnection();
    $empty->on('FROM consignment_sale_line csl', static fn () => []);
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new ConsignmentService($empty))->settleAndPay('c1', '2026-01-01', '2026-01-31'),
        'settleAndPay rejects an empty period',
    );

    // A non-positive net payable is rejected.
    $zero = new FakeConnection();
    $zero->on('FROM consignment_sale_line csl', static fn () => [
        ['id' => 'l1', 'sale_price' => '100.00', 'commission_amount' => '100.00', 'net_to_consignor' => '0.00'],
    ]);
    $zero->on('INSERT INTO consignor_settlement', static fn () => [['id' => 'set-1']]);
    $zero->on('INSERT INTO settlement_line', static fn () => null);
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new ConsignmentService($zero))->settleAndPay('c1', '2026-01-01', '2026-01-31'),
        'settleAndPay rejects a non-positive net',
    );

    // Unknown payout method is rejected.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new ConsignmentService(new FakeConnection()))->settleAndPay('c1', '2026-01-01', '2026-01-31', 'USD', 'crypto'),
        'settleAndPay rejects an unknown method',
    );

    // ---- VendorMallService: createLease -----------------------------------
    $t->suite('VendorMallService (params)');

    $vm = new FakeConnection();
    $vm->on("INSERT INTO lease\n", static fn () => [['id' => 'lease-1']]);
    $mall = new VendorMallService($vm);

    $mall->createLease('lessee-1', 'loc-1', '2026-01-01', '2026-12-31', 15, 'note');
    $leaseCall = $vm->findCall("INSERT INTO lease\n");
    $t->assertSame(
        [
            'lessee' => 'lessee-1',
            'location' => 'loc-1',
            'start' => '2026-01-01',
            'end' => '2026-12-31',
            'billing_day' => 15,
            'notes' => 'note',
        ],
        $leaseCall['params'],
        'createLease binds every column',
    );

    // Billing-day boundaries.
    $t->assertSame('lease-1', $mall->createLease('l', 'loc', billingDay: 1), 'billing day 1 is allowed');
    $t->assertSame('lease-1', $mall->createLease('l', 'loc', billingDay: 28), 'billing day 28 is allowed');
    $t->assertThrows(InvalidArgumentException::class, fn () => $mall->createLease('l', 'loc', billingDay: 0), 'billing day 0 is rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $mall->createLease('l', 'loc', billingDay: 29), 'billing day 29 is rejected');

    // ---- allocateSpace ----------------------------------------------------
    $vm->on('UPDATE lease_space SET thru_date', static fn () => null);
    $vm->on('INSERT INTO lease_space', static fn () => null);
    $vm->on('UPDATE space SET status', static fn () => null);

    $mall->allocateSpace('lease-1', 'space-1', '2026-04-01');
    $t->assertSame(
        ['from' => '2026-04-01', 'space' => 'space-1'],
        $vm->findCall('UPDATE lease_space SET thru_date')['params'],
        'allocateSpace ends the prior allocation',
    );
    $t->assertSame(
        ['lease' => 'lease-1', 'space' => 'space-1', 'from' => '2026-04-01'],
        $vm->findCall('INSERT INTO lease_space')['params'],
        'allocateSpace opens the new allocation',
    );
    $t->assertSame(['id' => 'space-1'], $vm->findCall('UPDATE space SET status')['params'], 'allocateSpace marks the space leased');

    // ---- addRentComponent -------------------------------------------------
    $vm->on('INSERT INTO rent_component', static fn () => [['id' => 'rc-1']]);

    $mall->addRentComponent('lease-1', 'base_rent', '1500.00', 'USD', null, null, 'quarterly', '2026-01-01', '2026-12-31');
    $rcCall = $vm->findCall('INSERT INTO rent_component');
    $t->assertSame(
        [
            'lease' => 'lease-1',
            'type' => 'base_rent',
            'amount' => '1500.00',
            'currency' => 'USD',
            'rate' => null,
            'breakpoint' => null,
            'frequency' => 'quarterly',
            'from' => '2026-01-01',
            'thru' => '2026-12-31',
        ],
        $rcCall['params'],
        'addRentComponent binds every column',
    );

    // Percentage rent requires a rate.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $mall->addRentComponent('lease-1', 'percentage_rent'),
        'percentage rent without a rate is rejected',
    );
    $t->assertSame('rc-1', $mall->addRentComponent('lease-1', 'percentage_rent', percentRate: '0.05'), 'percentage rent with a rate is accepted');

    // Unknown billing frequency is rejected.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $mall->addRentComponent('lease-1', 'base_rent', billingFrequency: 'weekly'),
        'unknown billing frequency is rejected',
    );

    // ---- billRent ---------------------------------------------------------
    $vm->on('post_rent_invoice', static fn () => 'rent-entry');
    $entry = $mall->billRent('lease-1', '2026-01-01', '2026-01-31', '2026-02-01');
    $t->assertSame('rent-entry', $entry, 'billRent returns the journal entry id');
    $t->assertSame(
        [
            'lease' => 'lease-1',
            'start' => '2026-01-01',
            'end' => '2026-01-31',
            'date' => '2026-02-01',
            'key' => 'rent:lease-1:2026-01-01:2026-01-31',
        ],
        $vm->findCall('post_rent_invoice')['params'],
        'billRent binds the period and derives the idempotency key',
    );

    // ---- recordDeposit ----------------------------------------------------
    $vm->on('INSERT INTO lease_deposit', static fn () => [['id' => 'dep-1']]);
    $vm->on('post_deposit_receipt', static fn () => 'dep-entry');

    $entry = $mall->recordDeposit('lease-1', '500.00', 'USD', '2026-02-01');
    $t->assertSame('dep-entry', $entry, 'recordDeposit returns the journal entry id');
    $t->assertSame(
        ['lease' => 'lease-1', 'amount' => '500.00', 'currency' => 'USD'],
        $vm->findCall('INSERT INTO lease_deposit')['params'],
        'recordDeposit binds the deposit row',
    );
    $t->assertSame(
        ['deposit' => 'dep-1', 'date' => '2026-02-01', 'key' => 'deposit:dep-1'],
        $vm->findCall('post_deposit_receipt')['params'],
        'recordDeposit derives the idempotency key',
    );
};
