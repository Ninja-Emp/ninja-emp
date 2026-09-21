<?php
declare(strict_types=1);

/**
 * Realistic seed data for the Tenant UI mock layer.
 *
 * Shapes mirror the real schema (SRS Parts 3–5): location → floor → space,
 * party (vendor/consignor), inventory item, sale, and the vendor payable views.
 * Money values are STRINGS (bcmath), never floats.
 *
 * @return array<string,mixed>
 */
return [
    'tenant' => [
        'name'     => 'Riverbend Marketplace',
        'slug'     => 'riverbend',
        'currency' => 'USD',
        'timezone' => 'America/Chicago',
    ],

    'locations' => [
        ['id' => 'loc-1', 'code' => 'RBM', 'name' => 'Riverbend Marketplace', 'city' => 'Springfield', 'state' => 'IL'],
    ],

    'floors' => [
        ['id' => 'flr-1', 'location_id' => 'loc-1', 'name' => 'Main Floor', 'level_no' => 1],
    ],

    // Spaces = booths. status: available|reserved|leased|maintenance|inactive
    'spaces' => [
        ['id' => 'sp-1',  'code' => 'A-11', 'floor_id' => 'flr-1', 'type' => 'inline',  'sqft' => 110, 'status' => 'leased',      'vendor_id' => 'v-1', 'rent' => '450.0000', 'x' => 1, 'y' => 1, 'w' => 2, 'h' => 2],
        ['id' => 'sp-2',  'code' => 'A-12', 'floor_id' => 'flr-1', 'type' => 'inline',  'sqft' => 120, 'status' => 'leased',      'vendor_id' => 'v-2', 'rent' => '475.0000', 'x' => 3, 'y' => 1, 'w' => 2, 'h' => 2],
        ['id' => 'sp-3',  'code' => 'A-13', 'floor_id' => 'flr-1', 'type' => 'inline',  'sqft' => 110, 'status' => 'leased',      'vendor_id' => 'v-3', 'rent' => '450.0000', 'x' => 5, 'y' => 1, 'w' => 2, 'h' => 2],
        ['id' => 'sp-4',  'code' => 'A-14', 'floor_id' => 'flr-1', 'type' => 'inline',  'sqft' => 110, 'status' => 'available',   'vendor_id' => null,  'rent' => '450.0000', 'x' => 7, 'y' => 1, 'w' => 2, 'h' => 2],
        ['id' => 'sp-5',  'code' => 'B-01', 'floor_id' => 'flr-1', 'type' => 'endcap',  'sqft' => 80,  'status' => 'leased',      'vendor_id' => 'v-4', 'rent' => '325.0000', 'x' => 1, 'y' => 4, 'w' => 2, 'h' => 2],
        ['id' => 'sp-6',  'code' => 'B-02', 'floor_id' => 'flr-1', 'type' => 'endcap',  'sqft' => 80,  'status' => 'available',   'vendor_id' => null,  'rent' => '325.0000', 'x' => 3, 'y' => 4, 'w' => 2, 'h' => 2],
        ['id' => 'sp-7',  'code' => 'B-03', 'floor_id' => 'flr-1', 'type' => 'endcap',  'sqft' => 80,  'status' => 'maintenance', 'vendor_id' => null,  'rent' => '325.0000', 'x' => 5, 'y' => 4, 'w' => 2, 'h' => 2],
        ['id' => 'sp-8',  'code' => 'K-1',  'floor_id' => 'flr-1', 'type' => 'kiosk',   'sqft' => 40,  'status' => 'leased',      'vendor_id' => 'v-5', 'rent' => '275.0000', 'x' => 8, 'y' => 4, 'w' => 1, 'h' => 1],
        ['id' => 'sp-9',  'code' => 'K-2',  'floor_id' => 'flr-1', 'type' => 'kiosk',   'sqft' => 40,  'status' => 'available',   'vendor_id' => null,  'rent' => '275.0000', 'x' => 9, 'y' => 4, 'w' => 1, 'h' => 1],
        ['id' => 'sp-10', 'code' => 'C-1',  'floor_id' => 'flr-1', 'type' => 'cart',    'sqft' => 24,  'status' => 'leased',      'vendor_id' => 'v-6', 'rent' => '200.0000', 'x' => 8, 'y' => 1, 'w' => 1, 'h' => 1],
    ],

    // Vendors / consignors (party with a vendor role). balance = what we owe them.
    'vendors' => [
        ['id' => 'v-1', 'name' => 'The Quilt Corner',        'contact' => 'Mabel Hart',    'email' => 'mabel@quiltcorner.example',  'phone' => '(555) 201-3344', 'type' => 'consignor', 'commission' => '20.0000', 'balance' => '842.5000',  'status' => 'active',   'since' => '2024-03-01'],
        ['id' => 'v-2', 'name' => 'Grandma\u2019s Jams & Jellies', 'contact' => 'Rose Delgado', 'email' => 'rose@jams.example',     'phone' => '(555) 201-7788', 'type' => 'consignor', 'commission' => '20.0000', 'balance' => '1247.7500', 'status' => 'active',   'since' => '2023-11-15'],
        ['id' => 'v-3', 'name' => 'Handmade Soaps by Dee',   'contact' => 'Dee Okafor',    'email' => 'dee@soaps.example',          'phone' => '(555) 201-9911', 'type' => 'consignor', 'commission' => '25.0000', 'balance' => '318.0000',  'status' => 'active',   'since' => '2024-06-20'],
        ['id' => 'v-4', 'name' => 'Sweet Treats Bakery',     'contact' => 'Luis Romero',   'email' => 'luis@sweettreats.example',   'phone' => '(555) 201-2233', 'type' => 'vendor',    'commission' => '15.0000', 'balance' => '0.0000',    'status' => 'active',   'since' => '2024-01-10'],
        ['id' => 'v-5', 'name' => 'Kettle Corn Cart',        'contact' => 'Nina Patel',    'email' => 'nina@kettlecorn.example',    'phone' => '(555) 201-5566', 'type' => 'vendor',    'commission' => '15.0000', 'balance' => '96.2500',   'status' => 'active',   'since' => '2025-02-01'],
        ['id' => 'v-6', 'name' => 'Willow & Vine Antiques',  'contact' => 'Harold Bishop', 'email' => 'harold@willowvine.example',  'phone' => '(555) 201-6677', 'type' => 'consignor', 'commission' => '30.0000', 'balance' => '512.4000',  'status' => 'paused',   'since' => '2023-08-05'],
    ],

    // Inventory items. cost = weighted-average cost (string).
    'items' => [
        ['id' => 'it-1',  'sku' => 'JAM-BLU-L', 'name' => 'Blueberry Jam (large jar)', 'vendor_id' => 'v-2', 'category' => 'Food',      'price' => '15.0000', 'cost' => '6.0000',  'on_hand' => 24, 'reorder' => 10, 'barcode' => '810000000011', 'owner' => 'vendor'],
        ['id' => 'it-2',  'sku' => 'JAM-STR-S', 'name' => 'Strawberry Preserves',      'vendor_id' => 'v-2', 'category' => 'Food',      'price' => '12.5000', 'cost' => '5.0000',  'on_hand' => 8,  'reorder' => 10, 'barcode' => '810000000028', 'owner' => 'vendor'],
        ['id' => 'it-3',  'sku' => 'JAM-GRP-S', 'name' => 'Grape Jelly (small jar)',   'vendor_id' => 'v-2', 'category' => 'Food',      'price' => '9.0000',  'cost' => '3.5000',  'on_hand' => 31, 'reorder' => 10, 'barcode' => '810000000035', 'owner' => 'vendor'],
        ['id' => 'it-4',  'sku' => 'HNY-LOC-L', 'name' => 'Local Honey (large jar)',   'vendor_id' => 'v-2', 'category' => 'Food',      'price' => '16.0000', 'cost' => '7.0000',  'on_hand' => 12, 'reorder' => 8,  'barcode' => '810000000042', 'owner' => 'vendor'],
        ['id' => 'it-5',  'sku' => 'SOAP-LAV',  'name' => 'Lavender Soap Bar',         'vendor_id' => 'v-3', 'category' => 'Bath',      'price' => '8.0000',  'cost' => '2.5000',  'on_hand' => 46, 'reorder' => 15, 'barcode' => '810000000059', 'owner' => 'vendor'],
        ['id' => 'it-6',  'sku' => 'SOAP-OAT',  'name' => 'Oatmeal Soap Bar',          'vendor_id' => 'v-3', 'category' => 'Bath',      'price' => '8.0000',  'cost' => '2.5000',  'on_hand' => 5,  'reorder' => 15, 'barcode' => '810000000066', 'owner' => 'vendor'],
        ['id' => 'it-7',  'sku' => 'QUILT-TW',  'name' => 'Twin Quilt (handmade)',     'vendor_id' => 'v-1', 'category' => 'Home',      'price' => '185.0000','cost' => '70.0000', 'on_hand' => 3,  'reorder' => 2,  'barcode' => '810000000073', 'owner' => 'vendor'],
        ['id' => 'it-8',  'sku' => 'QUILT-PL',  'name' => 'Throw Pillow (quilted)',    'vendor_id' => 'v-1', 'category' => 'Home',      'price' => '42.0000', 'cost' => '16.0000', 'on_hand' => 11, 'reorder' => 5,  'barcode' => '810000000080', 'owner' => 'vendor'],
        ['id' => 'it-9',  'sku' => 'FUDGE-BOX','name' => 'Chocolate Fudge (box)',     'vendor_id' => 'v-4', 'category' => 'Food',      'price' => '14.0000', 'cost' => '5.5000',  'on_hand' => 18, 'reorder' => 10, 'barcode' => '810000000097', 'owner' => 'vendor'],
        ['id' => 'it-10', 'sku' => 'BREAD-SD',  'name' => 'Fresh Sourdough Loaf',      'vendor_id' => 'v-4', 'category' => 'Food',      'price' => '8.0000',  'cost' => '2.7500',  'on_hand' => 2,  'reorder' => 12, 'barcode' => '810000000103', 'owner' => 'vendor'],
        ['id' => 'it-11', 'sku' => 'KETTLE-L',  'name' => 'Kettle Corn (large bag)',   'vendor_id' => 'v-5', 'category' => 'Food',      'price' => '7.0000',  'cost' => '2.0000',  'on_hand' => 40, 'reorder' => 20, 'barcode' => '810000000110', 'owner' => 'vendor'],
        ['id' => 'it-12', 'sku' => 'VASE-ANT',  'name' => 'Antique Porcelain Vase',    'vendor_id' => 'v-6', 'category' => 'Antiques',  'price' => '120.0000','cost' => '45.0000', 'on_hand' => 1,  'reorder' => 1,  'barcode' => '810000000127', 'owner' => 'vendor'],
    ],

    // Today's sales (already completed). Lines carry the commission split.
    'sales' => [
        ['id' => 's-1', 'no' => 'S-1042', 'time' => '10:14', 'register' => 'Front', 'cashier' => 'Sam Ortiz', 'total' => '15.0000', 'tenders' => ['cash'], 'lines' => [
            ['item_id' => 'it-1', 'name' => 'Blueberry Jam (large jar)', 'qty' => 1, 'price' => '15.0000', 'commission' => '3.0000', 'net' => '12.0000'],
        ]],
        ['id' => 's-2', 'no' => 'S-1043', 'time' => '11:02', 'register' => 'Front', 'cashier' => 'Sam Ortiz', 'total' => '23.0000', 'tenders' => ['card'], 'lines' => [
            ['item_id' => 'it-9', 'name' => 'Chocolate Fudge (box)', 'qty' => 1, 'price' => '14.0000', 'commission' => '2.8000', 'net' => '11.2000'],
            ['item_id' => 'it-3', 'name' => 'Grape Jelly (small jar)', 'qty' => 1, 'price' => '9.0000', 'commission' => '1.8000', 'net' => '7.2000'],
        ]],
        ['id' => 's-3', 'no' => 'S-1044', 'time' => '13:40', 'register' => 'Front', 'cashier' => 'Sam Ortiz', 'total' => '12.5000', 'tenders' => ['cash', 'card'], 'lines' => [
            ['item_id' => 'it-2', 'name' => 'Strawberry Preserves', 'qty' => 1, 'price' => '12.5000', 'commission' => '2.5000', 'net' => '10.0000'],
        ]],
        ['id' => 's-4', 'no' => 'S-1045', 'time' => '15:05', 'register' => 'Front', 'cashier' => 'Sam Ortiz', 'total' => '8.0000', 'tenders' => ['cash'], 'lines' => [
            ['item_id' => 'it-10', 'name' => 'Fresh Sourdough Loaf', 'qty' => 1, 'price' => '8.0000', 'commission' => '1.2000', 'net' => '6.8000'],
        ]],
        ['id' => 's-5', 'no' => 'S-1046', 'time' => '16:20', 'register' => 'Front', 'cashier' => 'Sam Ortiz', 'total' => '16.0000', 'tenders' => ['gift_certificate'], 'lines' => [
            ['item_id' => 'it-4', 'name' => 'Local Honey (large jar)', 'qty' => 1, 'price' => '16.0000', 'commission' => '3.2000', 'net' => '12.8000'],
        ]],
    ],

    // 14-day sales trend for the dashboard chart (strings).
    'sales_trend' => [
        ['day' => 'Sep 8',  'amount' => '412.0000'],
        ['day' => 'Sep 9',  'amount' => '388.5000'],
        ['day' => 'Sep 10', 'amount' => '501.2500'],
        ['day' => 'Sep 11', 'amount' => '466.0000'],
        ['day' => 'Sep 12', 'amount' => '612.7500'],
        ['day' => 'Sep 13', 'amount' => '704.0000'],
        ['day' => 'Sep 14', 'amount' => '655.5000'],
        ['day' => 'Sep 15', 'amount' => '498.0000'],
        ['day' => 'Sep 16', 'amount' => '523.2500'],
        ['day' => 'Sep 17', 'amount' => '587.0000'],
        ['day' => 'Sep 18', 'amount' => '641.5000'],
        ['day' => 'Sep 19', 'amount' => '712.0000'],
        ['day' => 'Sep 20', 'amount' => '689.7500'],
        ['day' => 'Sep 21', 'amount' => '263.0000'],
    ],

    'registers' => [
        ['id' => 'reg-1', 'name' => 'Front Register', 'status' => 'open',   'cashier' => 'Sam Ortiz', 'opened' => '09:00', 'drawer' => '200.0000', 'float' => '200.0000', 'counted' => null, 'variance' => null],
        ['id' => 'reg-2', 'name' => 'Back Register',  'status' => 'closed', 'cashier' => null,        'opened' => null,    'drawer' => '0.0000', 'float' => '0.0000', 'counted' => null, 'variance' => null],
    ],

    'tax_rates' => [
        ['id' => 'tx-1', 'name' => 'State Sales Tax', 'rate' => '6.2500'],
        ['id' => 'tx-2', 'name' => 'City Sales Tax',  'rate' => '2.0000'],
    ],
];
