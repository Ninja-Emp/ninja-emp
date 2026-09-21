<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;

/**
 * Dashboard — the operator's at-a-glance overview.
 */
final class DashboardController extends Controller
{
    public function index(array $params = []): void
    {
        $this->require('dashboard.view');

        $spaces = $this->repo->spaces();
        $statusCounts = $this->repo->spaceStatusCounts();
        $totalSpaces = count($spaces);
        $occupied = $statusCounts['leased'] + $statusCounts['reserved'];
        $occupancy = $totalSpaces > 0 ? (int) round($occupied / $totalSpaces * 100) : 0;

        $this->render('dashboard/index', [
            'title'          => 'Dashboard',
            'todaySales'     => $this->repo->todaySalesTotal(),
            'salesTrend'     => $this->repo->salesTrend(),
            'vendorPayable'  => $this->repo->totalVendorPayable(),
            'lowStockCount'  => $this->repo->lowStockCount(),
            'inventoryValue' => $this->repo->inventoryValue(),
            'statusCounts'   => $statusCounts,
            'totalSpaces'    => $totalSpaces,
            'occupancy'      => $occupancy,
            'recentSales'    => array_slice(array_reverse($this->repo->sales()), 0, 5),
            'lowStockItems'  => array_values(array_filter(
                $this->repo->items(),
                static fn (array $i): bool => $i['on_hand'] <= $i['reorder']
            )),
            'registers'      => $this->repo->registers(),
            'vendors'        => $this->repo->vendors(),
        ]);
    }
}
