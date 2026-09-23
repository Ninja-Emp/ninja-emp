<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEMP\Db\Sql\Value;
use NinjaEmp\TenantUi\Http\Controller;

/**
 * Reports — sales, vendor payouts, tax, inventory valuation.
 */
final class ReportController extends Controller
{
    /**
     * @param array<string,mixed> $params
     */
    public function index(array $params = []): void
    {
        $this->require('reports.view');

        $sales = $this->repo->sales();
        $trend = $this->repo->salesTrend();

        // Tender mix across today's sales.
        $tenderMix = [];

        foreach ($sales as $sale) {
            $tenders = $sale['tenders'] ?? null;

            if (!\is_array($tenders)) {
                continue;
            }

            foreach ($tenders as $t) {
                $key = Value::str($t);
                $tenderMix[$key] = ($tenderMix[$key] ?? 0) + 1;
            }
        }

        // Vendor payout summary.
        $payouts = [];

        foreach ($this->repo->vendors() as $v) {
            $payouts[] = ['name' => $v['name'], 'balance' => $v['balance'], 'type' => $v['type']];
        }
        usort($payouts, static fn ($a, $b) => bccomp(Value::num($b['balance']), Value::num($a['balance']), 4));

        $this->render('reports/index', [
            'title'          => 'Reports',
            'todaySales'     => $this->repo->todaySalesTotal(),
            'trend'          => $trend,
            'tenderMix'      => $tenderMix,
            'payouts'        => $payouts,
            'inventoryValue' => $this->repo->inventoryValue(),
            'taxRates'       => $this->repo->taxRates(),
            'salesCount'     => \count($sales),
        ]);
    }
}
