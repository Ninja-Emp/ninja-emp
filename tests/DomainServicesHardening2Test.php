<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use InvalidArgumentException;
use NinjaEMP\Domain\Inventory\InventoryService;
use NinjaEMP\Domain\OpenItem\OpenItemService;
use NinjaEMP\Domain\StoredValue\StoredValueService;
use NinjaEMP\Tests\Support\FakeConnection;

require_once __DIR__ . '/Support/FakeConnection.php';

/**
 * Hardening tests for the inventory, stored-value, and open-item services: they
 * pin the exact SQL parameters and the validation branches that mutation testing
 * flagged as unverified.
 */
return static function (TestHarness $t): void {
    // ---- InventoryService ------------------------------------------------

    $t->suite('InventoryService (hardening)');

    $conn = new FakeConnection();
    $conn->on('INSERT INTO inventory_item', static fn () => [['id' => 'inv-1']]);
    $conn->on('receive_inventory', static fn () => 'entry-recv-1');
    $conn->on('adjust_inventory', static fn () => 'entry-adj-1');
    $conn->on('SELECT on_hand, avg_cost, currency FROM inventory_item', static fn () => [[
        'on_hand' => '5', 'avg_cost' => '2.0000', 'currency' => 'USD',
    ]]);
    $conn->on('COALESCE(sum(on_hand * avg_cost)', static fn () => '10.0000');
    $inv = new InventoryService($conn);

    $itemId = $inv->createItem('SKU-1', 'Widget', '9.99', 'USD', 'widgets', 'sup-1', 'each', '123456', '3');
    $t->assertSame('inv-1', $itemId, 'createItem returns the item id');
    $createCall = $conn->findCall('INSERT INTO inventory_item');
    $t->assertSame('SKU-1', $createCall['params']['sku'], 'createItem binds the sku');
    $t->assertSame('Widget', $createCall['params']['description'], 'createItem binds the description');
    $t->assertSame('widgets', $createCall['params']['category'], 'createItem binds the category');
    $t->assertSame('sup-1', $createCall['params']['supplier'], 'createItem binds the supplier');
    $t->assertSame('each', $createCall['params']['uom'], 'createItem binds the uom');
    $t->assertSame('9.99', $createCall['params']['list_price'], 'createItem binds the list price');
    $t->assertSame('USD', $createCall['params']['currency'], 'createItem binds the currency');
    $t->assertSame('3', $createCall['params']['reorder'], 'createItem binds the reorder point');
    $t->assertSame('123456', $createCall['params']['barcode'], 'createItem binds the barcode');

    $entry = $inv->receive('inv-1', '10', '2.50', true, '2026-03-01', 'key-r');
    $t->assertSame('entry-recv-1', $entry, 'receive returns the entry id');
    $recvCall = $conn->findCall('receive_inventory');
    $t->assertSame('inv-1', $recvCall['params']['item'], 'receive binds the item');
    $t->assertSame('10', $recvCall['params']['qty'], 'receive binds the quantity');
    $t->assertSame('2.50', $recvCall['params']['cost'], 'receive binds the unit cost');
    $t->assertSame('2026-03-01', $recvCall['params']['date'], 'receive binds the date');
    $t->assertSame('key-r', $recvCall['params']['key'], 'receive binds the idempotency key');
    $t->assertSame('true', $recvCall['params']['on_account'], 'receive binds on_account true');

    // on_account false binds the string false.
    $connCash = new FakeConnection();
    $connCash->on('receive_inventory', static fn () => 'entry-recv-2');
    (new InventoryService($connCash))->receive('inv-1', '1', '1.00', false);
    $t->assertSame('false', $connCash->findCall('receive_inventory')['params']['on_account'], 'receive binds on_account false');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new InventoryService(new FakeConnection()))->receive('inv-1', '0', '1.00'),
        'a non-positive receipt quantity is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new InventoryService(new FakeConnection()))->receive('inv-1', '1', '-1.00'),
        'a negative unit cost is rejected',
    );

    $adj = $inv->adjust('inv-1', '-2', 'shrink', '2026-03-02', 'key-a');
    $t->assertSame('entry-adj-1', $adj, 'adjust returns the entry id');
    $adjCall = $conn->findCall('adjust_inventory');
    $t->assertSame('-2', $adjCall['params']['delta'], 'adjust binds the delta');
    $t->assertSame('shrink', $adjCall['params']['memo'], 'adjust binds the memo');
    $t->assertSame('key-a', $adjCall['params']['key'], 'adjust binds the idempotency key');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new InventoryService(new FakeConnection()))->adjust('inv-1', '0'),
        'a zero adjustment is rejected',
    );

    $position = $inv->position('inv-1');
    $t->assertSame(['on_hand' => '5', 'avg_cost' => '2.0000', 'currency' => 'USD'], $position, 'position returns the on-hand state');

    $connMissing = new FakeConnection();
    $connMissing->on('SELECT on_hand, avg_cost, currency FROM inventory_item', static fn () => null);
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new InventoryService($connMissing))->position('nope'),
        'position on a missing item is rejected',
    );

    $t->assertSame('10.0000', $inv->totalValue('USD'), 'totalValue returns the summed value');

    // ---- StoredValueService ----------------------------------------------

    $t->suite('StoredValueService (hardening)');

    $svConn = new FakeConnection();
    $svConn->on('issue_stored_value', static fn () => 'sv-1');
    $svConn->on('redeem_stored_value', static fn () => 'entry-redeem-1');
    $svConn->on('recognize_breakage', static fn () => 'entry-break-1');
    $svConn->on('SELECT id, instrument_kind, code', static fn () => [[
        'id' => 'sv-1', 'instrument_kind' => 'gift_certificate', 'code' => 'GC-1',
        'party_id' => null, 'original_amount' => '50.0000', 'balance' => '50.0000',
        'currency' => 'USD', 'issued_date' => '2026-01-01', 'expires_date' => null,
        'status' => 'active', 'open_item_id' => 'oi-1',
    ]]);
    $svConn->on('COALESCE(sum(balance)', static fn () => '50.0000');
    $svConn->on('stored_value_control_check', static fn () => [['kind' => 'gift_certificate', 'difference' => '0.0000']]);
    $sv = new StoredValueService($svConn);

    $svId = $sv->issue(StoredValueService::GIFT_CERTIFICATE, 'GC-1', '50.00', 'party-1', '2026-01-01', true, '2027-01-01', 'key-i');
    $t->assertSame('sv-1', $svId, 'issue returns the stored value id');
    $issueCall = $svConn->findCall('issue_stored_value');
    $t->assertSame('gift_certificate', $issueCall['params']['kind'], 'issue binds the kind');
    $t->assertSame('GC-1', $issueCall['params']['code'], 'issue binds the code');
    $t->assertSame('party-1', $issueCall['params']['party'], 'issue binds the party');
    $t->assertSame('50.00', $issueCall['params']['amount'], 'issue binds the amount');
    $t->assertSame('2026-01-01', $issueCall['params']['date'], 'issue binds the date');
    $t->assertSame('true', $issueCall['params']['cash'], 'issue binds cash true');
    $t->assertSame('2027-01-01', $issueCall['params']['expires'], 'issue binds the expiry');
    $t->assertSame('key-i', $issueCall['params']['key'], 'issue binds the idempotency key');

    // A granted (non-cash) instrument binds cash false.
    $svGrant = new FakeConnection();
    $svGrant->on('issue_stored_value', static fn () => 'sv-2');
    (new StoredValueService($svGrant))->issue(StoredValueService::STORE_CREDIT, 'SC-1', '10.00', paidWithCash: false);
    $t->assertSame('false', $svGrant->findCall('issue_stored_value')['params']['cash'], 'a granted instrument binds cash false');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new StoredValueService(new FakeConnection()))->issue('coupon', 'X', '10.00'),
        'an unknown instrument kind is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new StoredValueService(new FakeConnection()))->issue(StoredValueService::GIFT_CERTIFICATE, '  ', '10.00'),
        'a blank code is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new StoredValueService(new FakeConnection()))->issue(StoredValueService::GIFT_CERTIFICATE, 'GC-1', '0.00'),
        'a non-positive amount is rejected',
    );

    $redeem = $sv->redeem('GC-1', '20.00', '2026-02-01', 'sale-1', null);
    $t->assertSame('entry-redeem-1', $redeem, 'redeem returns the entry id');
    $redeemCall = $svConn->findCall('redeem_stored_value');
    $t->assertSame('GC-1', $redeemCall['params']['code'], 'redeem binds the code');
    $t->assertSame('20.00', $redeemCall['params']['amount'], 'redeem binds the amount');
    $t->assertSame('sale-1', $redeemCall['params']['sale'], 'redeem binds the sale');
    $t->assertSame(null, $redeemCall['params']['entry'], 'redeem binds a null entry');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new StoredValueService(new FakeConnection()))->redeem('GC-1', '20.00'),
        'a redemption with no sale or entry is rejected',
    );

    $t->assertSame('entry-break-1', $sv->recognizeBreakage('2026-06-01', 'key-b'), 'recognizeBreakage returns the entry id');

    $svNone = new FakeConnection();
    $svNone->on('recognize_breakage', static fn () => null);
    $t->assertSame(null, (new StoredValueService($svNone))->recognizeBreakage(), 'recognizeBreakage returns null when not opted in');

    $found = $sv->find('GC-1');
    $t->assertSame('sv-1', $found['id'], 'find returns the instrument');
    $t->assertSame('50.0000', $found['balance'], 'find returns the balance');

    $svMissing = new FakeConnection();
    $svMissing->on('SELECT id, instrument_kind, code', static fn () => null);
    $t->assertSame(null, (new StoredValueService($svMissing))->find('nope'), 'find returns null for an unknown code');

    $t->assertSame('50.0000', $sv->outstanding(StoredValueService::GIFT_CERTIFICATE), 'outstanding returns the liability');
    $t->assertSame([['kind' => 'gift_certificate', 'difference' => '0.0000']], $sv->controlCheck(), 'controlCheck returns the reconciliation rows');

    // ---- OpenItemService --------------------------------------------------

    $t->suite('OpenItemService (hardening)');

    $oiConn = new FakeConnection();
    $oiConn->on('open_item_create', static fn () => 'oi-1');
    $oiConn->on('apply_payment', static fn () => 'entry-pay-1');
    $oiConn->on('write_off_open_item', static fn () => 'entry-wo-1');
    $oiConn->on('SELECT id, item_kind, document_no', static fn () => [[
        'id' => 'oi-1', 'item_kind' => 'invoice', 'document_no' => 'INV-1',
        'original_amount' => '100.0000', 'open_amount' => '100.0000', 'currency' => 'USD',
        'issue_date' => '2026-01-01', 'due_date' => '2026-02-01', 'status' => 'open',
    ]]);
    $oiConn->on('COALESCE(sum(open_amount) FILTER', static fn () => [[
        'current' => '0', 'd1_30' => '100.0000', 'd31_60' => '0', 'd61_90' => '0', 'd90_plus' => '0',
    ]]);
    $oiConn->on('open_item_control_check', static fn () => [['subledger' => 'ar', 'difference' => '0.0000']]);
    $oi = new OpenItemService($oiConn);

    $oiId = $oi->create('ar', 'party-1', 'invoice', '100.00', 'USD', '2026-01-01', '2026-02-01', 'ref-1', 'INV-1', 'entry-1');
    $t->assertSame('oi-1', $oiId, 'create returns the open item id');
    $createCall = $oiConn->findCall('open_item_create');
    $t->assertSame('ar', $createCall['params']['subledger'], 'create binds the subledger');
    $t->assertSame('party-1', $createCall['params']['party'], 'create binds the party');
    $t->assertSame('invoice', $createCall['params']['source'], 'create binds the source');
    $t->assertSame('ref-1', $createCall['params']['ref'], 'create binds the source ref');
    $t->assertSame('INV-1', $createCall['params']['doc'], 'create binds the document number');
    $t->assertSame('100.00', $createCall['params']['amount'], 'create binds the amount');
    $t->assertSame('USD', $createCall['params']['currency'], 'create binds the currency');
    $t->assertSame('2026-01-01', $createCall['params']['issue'], 'create binds the issue date');
    $t->assertSame('2026-02-01', $createCall['params']['due'], 'create binds the due date');
    $t->assertSame('entry-1', $createCall['params']['entry'], 'create binds the journal entry');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new OpenItemService(new FakeConnection()))->create('ar', 'p', 'invoice', '0.00', 'USD', '2026-01-01'),
        'a zero open item is rejected',
    );

    $pay = $oi->applyPayment('party-1', 'ar', '50.00', '2026-02-15', 'key-p');
    $t->assertSame('entry-pay-1', $pay, 'applyPayment returns the entry id');
    $payCall = $oiConn->findCall('apply_payment');
    $t->assertSame('party-1', $payCall['params']['party'], 'applyPayment binds the party');
    $t->assertSame('ar', $payCall['params']['subledger'], 'applyPayment binds the subledger');
    $t->assertSame('50.00', $payCall['params']['amount'], 'applyPayment binds the amount');
    $t->assertSame('2026-02-15', $payCall['params']['date'], 'applyPayment binds the date');
    $t->assertSame('key-p', $payCall['params']['key'], 'applyPayment binds the idempotency key');

    $wo = $oi->writeOff('oi-1', '2026-03-01', '100.00', 'bad debt', 'key-w');
    $t->assertSame('entry-wo-1', $wo, 'writeOff returns the entry id');
    $woCall = $oiConn->findCall('write_off_open_item');
    $t->assertSame('oi-1', $woCall['params']['item'], 'writeOff binds the item');
    $t->assertSame('100.00', $woCall['params']['amount'], 'writeOff binds the amount');
    $t->assertSame('bad debt', $woCall['params']['memo'], 'writeOff binds the memo');
    $t->assertSame('key-w', $woCall['params']['key'], 'writeOff binds the idempotency key');

    $open = $oi->openFor('party-1', 'ar');
    $t->assertSame('oi-1', $open[0]['id'], 'openFor returns the open items');

    $aging = $oi->aging('ar', '2026-03-01');
    $t->assertSame(
        ['current' => '0', '1_30' => '100.0000', '31_60' => '0', '61_90' => '0', '90_plus' => '0'],
        $aging,
        'aging returns the bucket map',
    );

    $t->assertSame([['subledger' => 'ar', 'difference' => '0.0000']], $oi->controlCheck(), 'controlCheck returns the reconciliation rows');
};
