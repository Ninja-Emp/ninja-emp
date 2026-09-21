<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;

/**
 * Vendors / consignors — list + detail with balances.
 * Detail ties to the realtime v_vendor_* views in the real app.
 */
final class VendorController extends Controller
{
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
            static fn (array $i): bool => $i['vendor_id'] === $vendor['id']
        ));
        $spaces = array_values(array_filter(
            $this->repo->spaces(),
            static fn (array $s): bool => $s['vendor_id'] === $vendor['id']
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
}
