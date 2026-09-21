<?php

declare(strict_types=1);

use NinjaEMP\Db\Value\Tenant;
use NinjaEMP\Repository\DbalRepository;
use NinjaEMP\Repository\RowMapper;
use NinjaEMP\Tests\Support\FakeConnection;
use NinjaEMP\Tests\TestHarness;

require_once __DIR__ . '/Support/FakeConnection.php';

return static function (TestHarness $t): void {
    $t->suite('Repository');

    $tenant = Tenant::of('11111111-1111-1111-1111-111111111111', 'tenant_riverbend', '22222222-2222-2222-2222-222222222222');

    // ---- RowMapper: money is always a 4-dp string, never a float ----------

    $t->assertSame('15.0000', RowMapper::money('15'), 'money normalises to 4dp');
    $t->assertSame('0.0000', RowMapper::money(null), 'null money is zero');
    $t->assertSame('1247.7500', RowMapper::money('1247.75'), 'money keeps precision');
    $t->assertSame('20.0000', RowMapper::percent('0.20'), 'percent_rate 0.20 -> 20.0000');
    $t->assertSame(24, RowMapper::int('24.0000'), 'int truncates numeric');
    $t->assertSame(true, RowMapper::bool('t'), 'pg boolean t -> true');
    $t->assertSame(false, RowMapper::bool('f'), 'pg boolean f -> false');
    $t->assertSame('2026-09-08', RowMapper::date('2026-09-08 10:14:00+00'), 'date trims to day');
    $t->assertSame('10:14', RowMapper::time('2026-09-08 10:14:00+00'), 'time extracts HH:MM');
    $t->assertSame('Sep 8', RowMapper::shortDay('2026-09-08'), 'short day label');

    // ---- RowMapper: space ------------------------------------------------

    $space = RowMapper::space([
        'id' => 'sp-1', 'code' => 'A-11', 'name' => 'Corner', 'floor_id' => 'flr-1',
        'space_type_code' => 'inline', 'area_sqft' => '110.00', 'status' => 'leased',
        'vendor_id' => 'v-1', 'rent' => '450', 'x' => '1', 'y' => '1', 'w' => '2', 'h' => '2',
    ]);
    $t->assertSame('sp-1', $space['id'], 'space id');
    $t->assertSame(110, $space['sqft'], 'space sqft is int');
    $t->assertSame('450.0000', $space['rent'], 'space rent is money string');
    $t->assertSame('v-1', $space['vendor_id'], 'space vendor');
    $t->assertSame(2, $space['w'], 'space width');

    $freeSpace = RowMapper::space(['id' => 'sp-2', 'code' => 'A-12', 'status' => 'available']);
    $t->assertSame(null, $freeSpace['vendor_id'], 'unleased space has null vendor');
    $t->assertSame(1, $freeSpace['x'], 'default x is 1');

    // ---- RowMapper: vendor ----------------------------------------------

    $vendor = RowMapper::vendor([
        'id' => 'v-1', 'display_name' => 'The Quilt Corner', 'role_type_code' => 'consignor',
        'agreement_status' => 'active', 'default_commission_rate' => '0.20',
        'balance' => '842.50', 'is_active' => 't', 'since' => '2024-03-01',
        'email' => 'mabel@quiltcorner.example', 'phone' => '(555) 201-3344', 'contact' => 'Mabel Hart',
    ]);
    $t->assertSame('consignor', $vendor['type'], 'consignor role maps to type');
    $t->assertSame('20.0000', $vendor['commission'], 'commission rate as percent');
    $t->assertSame('842.5000', $vendor['balance'], 'vendor balance is money string');
    $t->assertSame('active', $vendor['status'], 'active vendor');
    $t->assertSame('Mabel Hart', $vendor['contact'], 'vendor contact');

    $paused = RowMapper::vendor(['id' => 'v-6', 'display_name' => 'X', 'role_type_code' => 'consignor', 'agreement_status' => 'suspended', 'is_active' => 't']);
    $t->assertSame('paused', $paused['status'], 'suspended agreement -> paused');

    $inactive = RowMapper::vendor(['id' => 'v-7', 'display_name' => 'Y', 'role_type_code' => 'vendor', 'is_active' => 'f']);
    $t->assertSame('inactive', $inactive['status'], 'inactive party -> inactive');
    $t->assertSame('vendor', $inactive['type'], 'vendor role maps to type');

    // ---- RowMapper: items ------------------------------------------------

    $owned = RowMapper::ownedItem([
        'id' => 'it-1', 'sku' => 'JAM-BLU-L', 'description' => 'Blueberry Jam', 'category' => 'Food',
        'supplier_party_id' => 'v-2', 'on_hand' => '24.0000', 'avg_cost' => '6.00',
        'list_price' => '15.00', 'reorder_point' => '10.0000', 'barcode' => '810000000011',
    ]);
    $t->assertSame('store', $owned['owner'], 'owned item owner is store');
    $t->assertSame('15.0000', $owned['price'], 'owned item list price');
    $t->assertSame('6.0000', $owned['cost'], 'owned item avg cost');
    $t->assertSame(24, $owned['on_hand'], 'owned item on hand');
    $t->assertSame('v-2', $owned['vendor_id'], 'owned item supplier');

    $consigned = RowMapper::consignedItem([
        'id' => 'ci-1', 'sku' => 'VASE-ANT', 'description' => 'Antique Vase', 'category' => 'Antiques',
        'consignor_party_id' => 'v-6', 'agreed_price' => '120.00', 'status' => 'available', 'barcode' => '810000000127',
    ]);
    $t->assertSame('vendor', $consigned['owner'], 'consigned item owner is vendor');
    $t->assertSame('120.0000', $consigned['price'], 'consigned agreed price');
    $t->assertSame('0.0000', $consigned['cost'], 'consigned item has no cost');
    $t->assertSame(1, $consigned['on_hand'], 'available consigned item is on floor');

    $sold = RowMapper::consignedItem(['id' => 'ci-2', 'description' => 'Sold', 'agreed_price' => '10', 'status' => 'sold']);
    $t->assertSame(0, $sold['on_hand'], 'sold consigned item is off floor');

    // ---- RowMapper: register --------------------------------------------

    $open = RowMapper::register([
        'id' => 'reg-1', 'name' => 'Front Register', 'shift_open' => 't', 'opened_at' => '2026-09-08 09:00:00+00',
        'opening_float' => '200.00', 'drawer' => '200.00', 'cashier' => 'Sam Ortiz',
    ]);
    $t->assertSame('open', $open['status'], 'open register');
    $t->assertSame('09:00', $open['opened'], 'register opened time');
    $t->assertSame('200.0000', $open['float'], 'register float');
    $t->assertSame('Sam Ortiz', $open['cashier'], 'register cashier');

    $closed = RowMapper::register(['id' => 'reg-2', 'name' => 'Back', 'shift_open' => 'f']);
    $t->assertSame('closed', $closed['status'], 'closed register');
    $t->assertSame(null, $closed['cashier'], 'closed register has no cashier');

    // ---- RowMapper: sale -------------------------------------------------

    $sale = RowMapper::sale(
        ['id' => 's-1', 'sale_no' => '1042', 'created_at' => '2026-09-08 10:14:00+00', 'total' => '15.00',
         'register_name' => 'Front', 'cashier' => 'Sam Ortiz', 'tenders' => ['cash']],
        [['item_ref' => 'it-1', 'description' => 'Blueberry Jam', 'quantity' => '1', 'unit_price' => '15.00',
          'commission_amount' => '3.00', 'net_to_consignor' => '12.00']],
    );
    $t->assertSame('S-1042', $sale['no'], 'sale number prefixed');
    $t->assertSame('15.0000', $sale['total'], 'sale total money');
    $t->assertSame('10:14', $sale['time'], 'sale time');
    $t->assertSame(1, count($sale['lines']), 'sale has one line');
    $t->assertSame('3.0000', $sale['lines'][0]['commission'], 'line commission');
    $t->assertSame(['cash'], $sale['tenders'], 'sale tenders');

    // ---- DbalRepository: tenant -----------------------------------------

    $conn = new FakeConnection();
    $conn->on('FROM tenant_config', static fn (): array => [[
        'legal_name' => 'Riverbend Marketplace', 'functional_currency' => 'USD', 'timezone' => 'America/Chicago',
    ]]);
    $repo = new DbalRepository($conn, $tenant);

    $tenantData = $repo->tenant();
    $t->assertSame('Riverbend Marketplace', $tenantData['name'], 'tenant name from config');
    $t->assertSame('USD', $tenantData['currency'], 'tenant currency');
    $t->assertSame('America/Chicago', $tenantData['timezone'], 'tenant timezone');
    $t->assertSame('riverbend', $tenantData['slug'], 'slug derived from schema');
    $t->assertSame(1, $conn->transactionCount, 'tenant() runs in a transaction');

    // updateTenant issues an UPDATE with only the provided fields.
    $conn2 = new FakeConnection();
    $repo2 = new DbalRepository($conn2, $tenant);
    $repo2->updateTenant(['name' => 'New Name', 'currency' => 'eur']);
    $call = $conn2->findCall('UPDATE tenant_config');
    $t->assertTrue($call !== null, 'updateTenant issues UPDATE');
    $t->assertSame('New Name', $call['params']['name'], 'updateTenant binds name');
    $t->assertSame('EUR', $call['params']['currency'], 'updateTenant upper-cases currency');
    $t->assertFalse(isset($call['params']['timezone']), 'updateTenant omits absent fields');

    // ---- DbalRepository: spaces -----------------------------------------

    $conn3 = new FakeConnection();
    $conn3->on('FROM space s', static fn (): array => [[
        'id' => 'sp-1', 'code' => 'A-11', 'name' => 'Corner', 'floor_id' => 'flr-1',
        'space_type_code' => 'inline', 'area_sqft' => '110.00', 'status' => 'leased',
        'vendor_id' => 'v-1', 'rent' => '450', 'x' => '1', 'y' => '1', 'w' => '2', 'h' => '2',
    ]]);
    $repo3 = new DbalRepository($conn3, $tenant);
    $spaces = $repo3->spaces();
    $t->assertSame(1, count($spaces), 'spaces() returns rows');
    $t->assertSame('A-11', $spaces[0]['code'], 'space code mapped');
    $t->assertSame('450.0000', $spaces[0]['rent'], 'space rent mapped');

    // ---- DbalRepository: vendors ----------------------------------------

    $conn4 = new FakeConnection();
    $conn4->on('FROM party p', static fn (): array => [[
        'id' => 'v-1', 'display_name' => 'The Quilt Corner', 'role_type_code' => 'consignor',
        'agreement_status' => 'active', 'default_commission_rate' => '0.20', 'balance' => '842.50',
        'is_active' => 't', 'since' => '2024-03-01', 'email' => 'a@b.c', 'phone' => '555', 'contact' => 'Mabel',
    ]]);
    $repo4 = new DbalRepository($conn4, $tenant);
    $vendors = $repo4->vendors();
    $t->assertSame(1, count($vendors), 'vendors() returns rows');
    $t->assertSame('The Quilt Corner', $vendors[0]['name'], 'vendor name mapped');
    $t->assertSame('20.0000', $vendors[0]['commission'], 'vendor commission mapped');

    // ---- DbalRepository: items (owned + consigned union) ----------------

    $conn5 = new FakeConnection();
    $conn5->on('FROM inventory_item', static fn (): array => [
        ['id' => 'it-1', 'sku' => 'JAM', 'description' => 'Jam', 'category' => 'Food', 'supplier_party_id' => 'v-2',
         'on_hand' => '24', 'avg_cost' => '6', 'list_price' => '15', 'reorder_point' => '10', 'barcode' => '111', 'kind' => 'owned'],
        ['id' => 'ci-1', 'sku' => 'VASE', 'description' => 'Vase', 'category' => 'Antiques', 'supplier_party_id' => 'v-6',
         'on_hand' => '1', 'avg_cost' => '0', 'list_price' => '120', 'reorder_point' => '0', 'barcode' => '222', 'kind' => 'consigned'],
    ]);
    $repo5 = new DbalRepository($conn5, $tenant);
    $items = $repo5->items();
    $t->assertSame(2, count($items), 'items() returns both kinds');
    $t->assertSame('store', $items[0]['owner'], 'first item is owned');
    $t->assertSame('vendor', $items[1]['owner'], 'second item is consigned');

    // ---- DbalRepository: aggregates -------------------------------------

    $conn6 = new FakeConnection();
    $conn6->on('SUM(total)', static fn (): string => '263.0000');
    $conn6->on('v_vendor_balance_realtime', static fn (): string => '3016.9000');
    $conn6->on('on_hand <= COALESCE', static fn (): string => '4');
    $conn6->on('SUM(avg_cost * on_hand)', static fn (): string => '1234.5600');
    $conn6->on('GROUP BY status', static fn (): array => [
        ['status' => 'leased', 'n' => '6'], ['status' => 'available', 'n' => '3'], ['status' => 'maintenance', 'n' => '1'],
    ]);
    $repo6 = new DbalRepository($conn6, $tenant);
    $t->assertSame('263.0000', $repo6->todaySalesTotal(), 'today sales total');
    $t->assertSame('3016.9000', $repo6->totalVendorPayable(), 'total vendor payable');
    $t->assertSame(4, $repo6->lowStockCount(), 'low stock count');
    $t->assertSame('1234.5600', $repo6->inventoryValue(), 'inventory value');
    $counts = $repo6->spaceStatusCounts();
    $t->assertSame(6, $counts['leased'], 'leased count');
    $t->assertSame(3, $counts['available'], 'available count');
    $t->assertSame(0, $counts['reserved'], 'reserved count defaults to zero');

    // ---- DbalRepository: saveSpace issues the right statements ----------

    $conn7 = new FakeConnection();
    $conn7->on('INSERT INTO space', static fn (): string => 'sp-new');
    $conn7->on('SELECT id FROM floor', static fn (): string => 'flr-1');
    $repo7 = new DbalRepository($conn7, $tenant);
    $newId = $repo7->saveSpace(null, ['code' => 'C-9', 'name' => 'New', 'type' => 'kiosk', 'sqft' => '40', 'status' => 'available', 'x' => '3', 'y' => '4']);
    $t->assertSame('sp-new', $newId, 'saveSpace returns new id');
    $t->assertTrue($conn7->calledWith('INSERT INTO space_attribute'), 'saveSpace writes map attributes');
    $t->assertTrue($conn7->calledWith('INSERT INTO space'), 'saveSpace inserts the space');

    // ---- DbalRepository: purchaseFromVendor calls receive_inventory -----

    $conn8 = new FakeConnection();
    $conn8->on('INSERT INTO inventory_item', static fn (): string => 'it-new');
    $conn8->on('receive_inventory', static fn (): string => 'je-1');
    $repo8 = new DbalRepository($conn8, $tenant);
    $itemId = $repo8->purchaseFromVendor('v-4', ['name' => 'Fudge', 'sku' => 'FUDGE', 'cost' => '5.50', 'price' => '14', 'qty' => 10]);
    $t->assertSame('it-new', $itemId, 'purchaseFromVendor returns item id');
    $t->assertTrue($conn8->calledWith('receive_inventory'), 'purchaseFromVendor posts the receipt');
    $recv = $conn8->findCall('receive_inventory');
    $t->assertSame('10', $recv['params']['qty'], 'receipt quantity bound');
    $t->assertSame('5.5000', $recv['params']['cost'], 'receipt cost normalised');

    // ---- DbalRepository: closeRegister calls post_shift_close -----------

    $conn9 = new FakeConnection();
    $conn9->on('SELECT id FROM shift', static fn (): string => 'shift-1');
    $conn9->on('post_shift_close', static fn (): string => 'je-2');
    $repo9 = new DbalRepository($conn9, $tenant);
    $repo9->closeRegister('reg-1', '215.00');
    $t->assertTrue($conn9->calledWith('post_shift_close'), 'closeRegister posts the shift close');
    $close = $conn9->findCall('post_shift_close');
    $t->assertSame('215.0000', $close['params']['counted'], 'counted cash normalised');

    // ---- DbalRepository: openRegister inserts a shift -------------------

    $conn10 = new FakeConnection();
    $repo10 = new DbalRepository($conn10, $tenant);
    $repo10->openRegister('reg-1', 'Sam Ortiz', '200.00');
    $t->assertTrue($conn10->calledWith('INSERT INTO shift'), 'openRegister inserts a shift');
    $open = $conn10->findCall('INSERT INTO shift');
    $t->assertSame('200.0000', $open['params']['float'], 'opening float normalised');
    $t->assertSame('22222222-2222-2222-2222-222222222222', $open['params']['actor'], 'actor id bound when uuid');

    // ---- DbalRepository: saveVendor creates party + role + agreement ----

    $conn11 = new FakeConnection();
    $conn11->on('INSERT INTO party', static fn (): string => 'v-new');
    $repo11 = new DbalRepository($conn11, $tenant);
    $vendorId = $repo11->saveVendor(null, ['name' => 'New Consignor', 'type' => 'consignor', 'commission' => '25', 'email' => 'x@y.z']);
    $t->assertSame('v-new', $vendorId, 'saveVendor returns new id');
    $t->assertTrue($conn11->calledWith('INSERT INTO party_role'), 'saveVendor assigns a role');
    $t->assertTrue($conn11->calledWith('INSERT INTO consignor_agreement'), 'consignor gets an agreement');
    $t->assertTrue($conn11->calledWith('INSERT INTO party_contact_mechanism'), 'saveVendor stores contact');
    $agreement = $conn11->findCall('INSERT INTO consignor_agreement');
    $t->assertSame('0.250000', $agreement['params']['rate'], 'commission percent -> rate');

    // ---- DbalRepository: saveItem routes by owner -----------------------

    $conn12 = new FakeConnection();
    $conn12->on('INSERT INTO inventory_item', static fn (): string => 'it-owned');
    $conn12->on('INSERT INTO consignment_item', static fn (): string => 'ci-consigned');
    $conn12->on('SELECT id FROM consignor_agreement', static fn (): string => 'agr-1');
    $repo12 = new DbalRepository($conn12, $tenant);
    $ownedId = $repo12->saveItem(null, ['owner' => 'store', 'name' => 'Owned', 'sku' => 'O1', 'price' => '9']);
    $t->assertSame('it-owned', $ownedId, 'store item saved to inventory_item');
    $consignedId = $repo12->saveItem(null, ['owner' => 'vendor', 'name' => 'Consigned', 'sku' => 'C1', 'price' => '9', 'vendor_id' => 'v-1']);
    $t->assertSame('ci-consigned', $consignedId, 'vendor item saved to consignment_item');

    // A consigned item without a consignor is rejected before touching the DB.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $repo12->saveItem(null, ['owner' => 'vendor', 'name' => 'No vendor', 'price' => '9']),
        'consigned item requires a consignor',
    );

    // ---- DbalRepository: itemByBarcode ----------------------------------

    $conn13 = new FakeConnection();
    $conn13->on('FROM inventory_item', static fn (): array => [[
        'id' => 'it-1', 'sku' => 'JAM', 'description' => 'Jam', 'category' => 'Food', 'supplier_party_id' => null,
        'on_hand' => '5', 'avg_cost' => '2', 'list_price' => '8', 'reorder_point' => '1', 'barcode' => '810000000011', 'kind' => 'owned',
    ]]);
    $repo13 = new DbalRepository($conn13, $tenant);
    $found = $repo13->itemByBarcode('810000000011');
    $t->assertSame('it-1', $found['id'], 'itemByBarcode finds the item');
    $t->assertSame('8.0000', $found['price'], 'barcode lookup maps price');
};
