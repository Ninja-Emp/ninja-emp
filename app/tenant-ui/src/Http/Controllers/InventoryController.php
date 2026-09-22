<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;
use NinjaEMP\Db\Sql\Value;

/**
 * Inventory — items, stock levels, weighted-average cost, adjustments.
 *
 * Items may be vendor-owned (consignment) or store-owned. The store can also
 * buy goods from a vendor, which creates a store-owned item and a payable.
 */
final class InventoryController extends Controller
{
    /**
     * @param array<string,mixed> $params
     */
    public function index(array $params = []): void
    {
        $this->require('inventory.manage');

        $items = $this->repo->items();
        $q = strtolower($this->query('q'));

        if ($q !== '') {
            $items = array_values(array_filter($items, static function (array $i) use ($q): bool {
                return str_contains(strtolower($i['name']), $q)
                    || str_contains(strtolower($i['sku']), $q)
                    || str_contains(strtolower($i['category']), $q);
            }));
        }

        $this->render('inventory/index', [
            'title'          => 'Inventory',
            'items'          => $items,
            'vendorNames'    => $this->vendorNames(),
            'query'          => $this->query('q'),
            'lowStockCount'  => $this->repo->lowStockCount(),
            'inventoryValue' => $this->repo->inventoryValue(),
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function show(array $params): void
    {
        $this->require('inventory.manage');
        $item = $this->repo->item($params['id'] ?? '');

        if ($item === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);

            return;
        }
        $vendor = $item['vendor_id'] ? $this->repo->vendor($item['vendor_id']) : null;
        $this->render('inventory/show', [
            'title'  => $item['name'],
            'item'   => $item,
            'vendor' => $vendor,
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function create(array $params = []): void
    {
        $this->require('inventory.manage');
        $this->render('inventory/form', [
            'title'   => 'New Item',
            'item'    => null,
            'vendors' => $this->repo->vendors(),
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function edit(array $params): void
    {
        $this->require('inventory.manage');
        $item = $this->repo->item($params['id'] ?? '');

        if ($item === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);

            return;
        }
        $this->render('inventory/form', [
            'title'   => 'Edit ' . $item['name'],
            'item'    => $item,
            'vendors' => $this->repo->vendors(),
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function store(array $params = []): void
    {
        $this->require('inventory.manage');
        $id = $this->repo->saveItem(null, $this->fields());
        $this->flash('success', 'Item created.');
        $this->redirect('/inventory/' . $id);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function update(array $params): void
    {
        $this->require('inventory.manage');
        $id = $params['id'] ?? '';
        $this->repo->saveItem($id, $this->fields());
        $this->flash('success', 'Item updated.');
        $this->redirect('/inventory/' . $id);
    }

    /** Normalise the item form into repository fields. */
    private function fields(): array
    {
        $owner = $this->input('owner', 'vendor') === 'store' ? 'store' : 'vendor';
        $vendorId = $this->input('vendor_id');

        return [
            'name'      => $this->input('name'),
            'sku'       => $this->input('sku'),
            'barcode'   => $this->input('barcode'),
            'category'  => $this->input('category', 'General'),
            'price'     => $this->money('price'),
            'cost'      => $this->money('cost'),
            'on_hand'   => (int) $this->input('on_hand', '0'),
            'reorder'   => (int) $this->input('reorder', '0'),
            'owner'     => $owner,
            'vendor_id' => $owner === 'vendor' && $vendorId !== '' ? $vendorId : null,
        ];
    }

    /** Read a money field as a normalised string (4 dp). */
    private function money(string $key): string
    {
        $raw = preg_replace('/[^0-9.\-]/', '', $this->input($key, '0'));

        return $raw === '' ? '0.0000' : bcadd(Value::num($raw), '0', 4);
    }

    /** @return array<string,string> */
    private function vendorNames(): array
    {
        $names = [];

        foreach ($this->repo->vendors() as $v) {
            $names[$v['id']] = $v['name'];
        }

        return $names;
    }
}
