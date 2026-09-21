<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use NinjaEMP\Domain\Reporting\ReportingService;
use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Reporting surface: financial statements and operational reports.
 *
 * Date ranges come from query parameters (from/to), defaulting to the current
 * month. All figures are 4-dp decimal strings (ADR-0002).
 */
final class ReportingController
{
    public function __construct(private readonly ReportingService $reports)
    {
    }

    #[Route('GET', '/api/reports/income-statement', name: 'reports.income_statement', permission: 'reports.view')]
    #[ApiSchema(
        summary: 'Income statement (accrual)',
        description: 'Accrual-basis profit & loss for a date range.',
        tags: ['Reports'],
        errors: [401, 403],
    )]
    public function incomeStatement(ServerRequestInterface $request, array $params): ResponseInterface
    {
        [$from, $to] = $this->range($request);

        return JsonResponse::of([
            'from' => $from,
            'to' => $to,
            'basis' => 'accrual',
            'lines' => $this->reports->incomeStatement($from, $to),
        ]);
    }

    #[Route('GET', '/api/reports/cash-basis', name: 'reports.cash_basis', permission: 'reports.view')]
    #[ApiSchema(
        summary: 'Income statement (cash basis)',
        description: 'Cash-basis profit & loss derived from accrual + open-item settlement.',
        tags: ['Reports'],
        errors: [401, 403],
    )]
    public function cashBasis(ServerRequestInterface $request, array $params): ResponseInterface
    {
        [$from, $to] = $this->range($request);

        return JsonResponse::of([
            'from' => $from,
            'to' => $to,
            'basis' => 'cash',
            'lines' => $this->reports->cashBasisIncomeStatement($from, $to),
        ]);
    }

    #[Route('GET', '/api/reports/balance-sheet', name: 'reports.balance_sheet', permission: 'reports.view')]
    #[ApiSchema(
        summary: 'Balance sheet',
        description: 'Assets, liabilities and equity as of a date.',
        tags: ['Reports'],
        errors: [401, 403],
    )]
    public function balanceSheet(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $asOf = $this->query($request, 'as_of') ?? date('Y-m-d');

        return JsonResponse::of([
            'as_of' => $asOf,
            'lines' => $this->reports->balanceSheet($asOf),
            'check' => $this->reports->balanceSheetCheck($asOf),
        ]);
    }

    #[Route('GET', '/api/reports/sales', name: 'reports.sales', permission: 'reports.view')]
    #[ApiSchema(
        summary: 'Sales summary',
        description: 'Sales totals for a date range, with a per-day trend.',
        tags: ['Reports'],
        errors: [401, 403],
    )]
    public function sales(ServerRequestInterface $request, array $params): ResponseInterface
    {
        [$from, $to] = $this->range($request);

        return JsonResponse::of([
            'from' => $from,
            'to' => $to,
            'summary' => $this->reports->salesSummary($from, $to),
            'by_day' => $this->reports->salesByDay($from, $to),
            'top_items' => $this->reports->topItems($from, $to),
        ]);
    }

    #[Route('GET', '/api/reports/inventory-valuation', name: 'reports.inventory_valuation', permission: 'reports.view')]
    #[ApiSchema(
        summary: 'Inventory valuation',
        description: 'Owned stock valued at moving weighted average (ADR-0031).',
        tags: ['Reports'],
        errors: [401, 403],
    )]
    public function inventoryValuation(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $currency = $this->query($request, 'currency') ?? 'USD';

        return JsonResponse::of(['data' => $this->reports->inventoryValuation($currency)]);
    }

    #[Route('GET', '/api/reports/tax', name: 'reports.tax', permission: 'reports.view')]
    #[ApiSchema(
        summary: 'Tax collected',
        description: 'Tax collected by jurisdiction for a date range.',
        tags: ['Reports'],
        errors: [401, 403],
    )]
    public function tax(ServerRequestInterface $request, array $params): ResponseInterface
    {
        [$from, $to] = $this->range($request);

        return JsonResponse::of([
            'from' => $from,
            'to' => $to,
            'jurisdictions' => $this->reports->taxCollected($from, $to),
        ]);
    }

    /**
     * @return array{0:string,1:string}
     */
    private function range(ServerRequestInterface $request): array
    {
        $from = $this->query($request, 'from') ?? date('Y-m-01');
        $to = $this->query($request, 'to') ?? date('Y-m-t');

        return [$from, $to];
    }

    private function query(ServerRequestInterface $request, string $key): ?string
    {
        $params = $request->getQueryParams();
        $value = $params[$key] ?? null;

        return is_string($value) && $value !== '' ? $value : null;
    }
}
