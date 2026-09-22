<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;
use NinjaEMP\Db\Sql\Value;

/**
 * Vendors / consignors — list, detail with balances, create/edit, and
 * "buy from vendor" (store purchases goods, creating a payable).
 * Detail ties to the realtime v_vendor_* views in the real app.
 */
final class VendorController extends Controller
{
    /**
     * @param array<string,mixed> $params
     */
    public function index(array $params = []): void
    {
        $this->require('vendors.manage');

        $vendors = $this->repo->vendors();
        $spaces = $this->repo->spaces();

        // Map vendor -> booth code(s).
        $booths = [];

        foreach ($spaces as $s) {
            if ($s['vendor_id']) {
                $booths[$s['vendor_id']][] = $s['code'];
            }
        }

        $this->render('vendors/index', [
            'title'   => 'Vendors',
            'vendors' => $vendors,
            'booths'  => $booths,
            'totalPayable' => $this->repo->totalVendorPayable(),
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function show(array $params): void
    {
        $this->require('vendors.manage');
        $vendor = $this->repo->vendor($params['id'] ?? '');

        if ($vendor === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);

            return;
        }

        $items = array_values(array_filter(
            $this->repo->items(),
            static fn (array $i): bool => $i['vendor_id'] === $vendor['id'],
        ));
        $spaces = array_values(array_filter(
            $this->repo->spaces(),
            static fn (array $s): bool => $s['vendor_id'] === $vendor['id'],
        ));

        // Mock statement lines derived from sales containing this vendor's items.
        $statement = [];

        foreach ($this->repo->sales() as $sale) {
            foreach ($sale['lines'] as $line) {
                $item = $this->repo->item($line['item_id']);

                if ($item && $item['vendor_id'] === $vendor['id']) {
                    $statement[] = [
                        'no'         => $sale['no'],
                        'time'       => $sale['time'],
                        'item'       => $line['name'],
                        'gross'      => $line['price'],
                        'commission' => $line['commission'],
                        'net'        => $line['net'],
                    ];
                }
            }
        }

        $this->render('vendors/show', [
            'title'     => $vendor['name'],
            'vendor'    => $vendor,
            'items'     => $items,
            'spaces'    => $spaces,
            'statement' => $statement,
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function create(array $params = []): void
    {
        $this->require('vendors.manage');
        $this->render('vendors/form', [
            'title'  => 'New Vendor',
            'vendor' => null,
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function edit(array $params): void
    {
        $this->require('vendors.manage');
        $vendor = $this->repo->vendor($params['id'] ?? '');

        if ($vendor === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);

            return;
        }
        $this->render('vendors/form', [
            'title'  => 'Edit ' . $vendor['name'],
            'vendor' => $vendor,
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function store(array $params = []): void
    {
        $this->require('vendors.manage');
        $id = $this->repo->saveVendor(null, $this->fields());
        $this->flash('success', 'Vendor created.');
        $this->redirect('/vendors/' . $id);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function update(array $params): void
    {
        $this->require('vendors.manage');
        $id = $params['id'] ?? '';
        $this->repo->saveVendor($id, $this->fields());
        $this->flash('success', 'Vendor updated.');
        $this->redirect('/vendors/' . $id);
    }

    /** Store buys goods from a vendor (creates a store-owned item + payable). */
    /**
     * @param array<string,mixed> $params
     */
    public function purchase(array $params): void
    {
        $this->require('vendors.manage');
        $vendorId = $params['id'] ?? '';

        if ($this->repo->vendor($vendorId) === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);

            return;
        }
        $this->repo->purchaseFromVendor($vendorId, [
            'name'     => $this->input('name', 'Purchased item'),
            'sku'      => $this->input('sku'),
            'barcode'  => $this->input('barcode'),
            'category' => $this->input('category', 'General'),
            'price'    => $this->money('price'),
            'cost'     => $this->money('cost'),
            'qty'      => max(1, (int) $this->input('qty', '1')),
        ]);
        $this->flash('success', 'Purchase recorded — item added to store inventory and vendor payable increased.');
        $this->redirect('/vendors/' . $vendorId);
    }

    /** Normalise the vendor form into repository fields. */
    private function fields(): array
    {
        return [
            'name'       => $this->input('name'),
            'contact'    => $this->input('contact'),
            'email'      => $this->input('email'),
            'phone'      => $this->input('phone'),
            'type'       => $this->input('type', 'consignor'),
            'commission' => $this->money('commission'),
            'status'     => $this->input('status', 'active'),
        ];
    }

    private function money(string $key): string
    {
        $raw = preg_replace('/[^0-9.\-]/', '', $this->input($key, '0'));

        return $raw === '' ? '0.0000' : bcadd(Value::num($raw), '0', 4);
    }
}
