<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;

/**
 * Inventory — items, stock levels, weighted-average cost, adjustments.
 */
final class InventoryController extends Controller
{
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

        $vendors = $this->repo->vendors();
        $vendorNames = [];
        foreach ($vendors as $v) {
            $vendorNames[$v['id']] = $v['name'];
        }

        $this->render('inventory/index', [
            'title'          => 'Inventory',
            'items'          => $items,
            'vendorNames'    => $vendorNames,
            'query'          => $this->query('q'),
            'lowStockCount'  => $this->repo->lowStockCount(),
            'inventoryValue' => $this->repo->inventoryValue(),
        ]);
    }

    public function show(array $params): void
    {
        $this->require('inventory.manage');
        $item = $this->repo->item($params['id'] ?? '');
        if ($item === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);
            return;
        }
        $vendor = $this->repo->vendor($item['vendor_id']);
        $this->render('inventory/show', [
            'title'  => $item['name'],
            'item'   => $item,
            'vendor' => $vendor,
        ]);
    }
}
