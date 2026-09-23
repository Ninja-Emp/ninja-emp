<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEMP\Db\Sql\Value;
use NinjaEmp\TenantUi\Http\Controller;

/**
 * Point of Sale — the priority surface.
 *
 * Barcode scanning, split payments, hold/resume, discounts, tax-free toggle.
 * There is deliberately NO catalog grid: in a vendor mall items are not in
 * inventory until they are sold, so the register adds items via scan or the
 * instant-inventory modal. The store can also sell its own goods and buy goods
 * from a vendor.
 */
final class PosController extends Controller
{
    /** Tender types mirror ADR-0029. */
    private const TENDERS = [
        ['id' => 'cash',             'label' => 'Cash',                 'icon' => 'i-wallet'],
        ['id' => 'check',            'label' => 'Check',                'icon' => 'i-receipt'],
        ['id' => 'card',             'label' => 'Card (clearing)',      'icon' => 'i-wallet'],
        ['id' => 'gift_certificate', 'label' => 'Gift Certificate',     'icon' => 'i-tag'],
        ['id' => 'store_credit',     'label' => 'Customer Store Credit','icon' => 'i-user'],
        ['id' => 'vendor_draw',      'label' => 'Vendor Payable Draw',  'icon' => 'i-vendor'],
    ];

    /**
     * @param array<string,mixed> $params
     */
    public function index(array $params = []): void
    {
        $this->require('pos.use');

        $registers = $this->repo->registers();
        $openRegister = null;

        foreach ($registers as $r) {
            if ($r['status'] === 'open') {
                $openRegister = $r;
                break;
            }
        }

        $this->render('pos/index', [
            'title'        => 'Point of Sale',
            'vendors'      => $this->repo->vendors(),
            'storeItems'   => array_values(array_filter(
                $this->repo->items(),
                static fn (array $i): bool => ($i['owner'] ?? 'vendor') === 'store',
            )),
            'tenders'      => self::TENDERS,
            'taxRates'     => $this->repo->taxRates(),
            'registers'    => $registers,
            'openRegister' => $openRegister,
            'pageScripts'  => ['/assets/js/pos.js'],
        ]);
    }

    /** Barcode/SKU lookup endpoint (JSON). */
    /**
     * @param array<string,mixed> $params
     */
    public function scan(array $params = []): void
    {
        $this->require('pos.use');
        header('Content-Type: application/json');

        $code = $this->input('code');
        $item = $code !== '' ? $this->repo->itemByBarcode($code) : null;

        if ($item === null) {
            http_response_code(404);
            echo json_encode(['ok' => false, 'error' => 'No item matches that code.']);

            return;
        }
        echo json_encode(['ok' => true, 'item' => $item]);
    }

    /**
     * Instant inventory: create an item at the register and return it so it can
     * be added to the cart. Vendor-owned by default (consignment); the store can
     * also quick-add its own goods with owner=store.
     *
     * @param array<string,mixed> $params
     */
    /**
     * @param array<string,mixed> $params
     */
    public function quickAdd(array $params = []): void
    {
        $this->require('pos.use');
        header('Content-Type: application/json');

        $name = $this->input('name');

        if ($name === '') {
            http_response_code(422);
            echo json_encode(['ok' => false, 'error' => 'A name is required.']);

            return;
        }

        $owner = $this->input('owner', 'vendor') === 'store' ? 'store' : 'vendor';
        $vendorId = $this->input('vendor_id');
        $price = $this->money('price');
        $cost = $this->money('cost');

        $id = $this->repo->saveItem(null, [
            'name'      => $name,
            'sku'       => $this->input('sku'),
            'barcode'   => $this->input('barcode'),
            'category'  => $this->input('category', 'General'),
            'price'     => $price,
            'cost'      => $cost,
            'on_hand'   => 1,
            'reorder'   => 0,
            'owner'     => $owner,
            'vendor_id' => $owner === 'vendor' && $vendorId !== '' ? $vendorId : null,
        ]);

        echo json_encode(['ok' => true, 'item' => $this->repo->item($id)]);
    }

    /** Store buys goods from a vendor (creates a store-owned item + payable). */
    /**
     * @param array<string,mixed> $params
     */
    public function buyFromVendor(array $params = []): void
    {
        $this->require('pos.use');
        header('Content-Type: application/json');

        $vendorId = $this->input('vendor_id');

        if ($vendorId === '' || $this->repo->vendor($vendorId) === null) {
            http_response_code(422);
            echo json_encode(['ok' => false, 'error' => 'Choose a vendor.']);

            return;
        }
        $id = $this->repo->purchaseFromVendor($vendorId, [
            'name'     => $this->input('name', 'Purchased item'),
            'sku'      => $this->input('sku'),
            'barcode'  => $this->input('barcode'),
            'category' => $this->input('category', 'General'),
            'price'    => $this->money('price'),
            'cost'     => $this->money('cost'),
            'qty'      => max(1, (int) $this->input('qty', '1')),
        ]);
        echo json_encode(['ok' => true, 'item' => $this->repo->item($id)]);
    }

    /** Checkout endpoint (mock posting). */
    /**
     * @param array<string,mixed> $params
     */
    public function checkout(array $params = []): void
    {
        $this->require('pos.use');
        header('Content-Type: application/json');

        // In the real app this posts a balanced journal entry (ADR-0020/0029).
        // Here we acknowledge and return a receipt number.
        $no = 'S-' . random_int(1047, 9999);
        echo json_encode(['ok' => true, 'receipt' => $no]);
    }

    private function money(string $key): string
    {
        $raw = preg_replace('/[^0-9.\-]/', '', $this->input($key, '0'));

        return $raw === '' ? '0.0000' : bcadd(Value::num($raw), '0', 4);
    }
}
