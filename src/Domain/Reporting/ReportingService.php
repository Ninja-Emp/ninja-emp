<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Reporting;

use NinjaEMP\Db\Connection;

/**
 * Reporting: financial statements and operational reports.
 *
 * The financial statements are the database's own functions (income_statement,
 * balance_sheet, cash_basis_income_statement, net_income, balance_sheet_check)
 * so the book of record is the ledger, not a re-derivation in PHP. Accrual is
 * the book of record (ADR-0022); the cash-basis statement is a derived view.
 *
 * Operational reports (sales, vendor balances, inventory valuation, aging) read
 * the realtime views and tables. Money comes back as 4-dp decimal strings.
 */
final class ReportingService
{
    public function __construct(private readonly Connection $conn)
    {
    }

    // ---- Financial statements ---------------------------------------------

    /**
     * Accrual-basis profit & loss for a date range.
     *
     * @return list<array<string, mixed>>
     */
    public function incomeStatement(string $from, string $to): array
    {
        return $this->conn->select(
            'SELECT * FROM income_statement(:from, :to)',
            ['from' => $from, 'to' => $to],
        )->toArray();
    }

    /**
     * Cash-basis profit & loss (derived from accrual + open-item settlement).
     *
     * @return list<array<string, mixed>>
     */
    public function cashBasisIncomeStatement(string $from, string $to): array
    {
        return $this->conn->select(
            'SELECT * FROM cash_basis_income_statement(:from, :to)',
            ['from' => $from, 'to' => $to],
        )->toArray();
    }

    /**
     * Balance sheet as of a date.
     *
     * @return list<array<string, mixed>>
     */
    public function balanceSheet(?string $asOf = null): array
    {
        $asOf ??= date('Y-m-d');

        return $this->conn->select('SELECT * FROM balance_sheet(:as_of)', ['as_of' => $asOf])->toArray();
    }

    /**
     * Net income for a date range (a single figure).
     */
    public function netIncome(string $from, string $to): string
    {
        return $this->conn->scalarString('SELECT net_income(:from, :to)', ['from' => $from, 'to' => $to]);
    }

    /**
     * Verify the balance sheet balances (assets = liabilities + equity).
     *
     * @return array<string, mixed>
     */
    public function balanceSheetCheck(?string $asOf = null): array
    {
        $asOf ??= date('Y-m-d');

        return $this->conn->selectOne('SELECT * FROM balance_sheet_check(:as_of)', ['as_of' => $asOf])->toArray();
    }

    // ---- Operational reports ----------------------------------------------

    /**
     * Sales summary for a date range: count, gross, discounts, tax, net.
     *
     * @return array<string, mixed>
     */
    public function salesSummary(string $from, string $to): array
    {
        return $this->conn->selectOne(
            'SELECT
                count(*)                                   AS sale_count,
                COALESCE(sum(subtotal), 0)                 AS subtotal,
                COALESCE(sum(discount_total), 0)           AS discount_total,
                COALESCE(sum(tax_total), 0)                AS tax_total,
                COALESCE(sum(total), 0)                    AS total,
                COALESCE(sum(total) FILTER (WHERE is_refund), 0) AS refunds
               FROM sale
              WHERE sale_date BETWEEN :from AND :to
                AND status IN (\'completed\', \'partially_refunded\', \'refunded\')',
            ['from' => $from, 'to' => $to],
        )->toArray();
    }

    /**
     * Sales by day for a date range (for a trend chart).
     *
     * @return list<array<string, mixed>>
     */
    public function salesByDay(string $from, string $to): array
    {
        return $this->conn->select(
            'SELECT sale_date, count(*) AS sale_count, COALESCE(sum(total), 0) AS total
               FROM sale
              WHERE sale_date BETWEEN :from AND :to
                AND status IN (\'completed\', \'partially_refunded\', \'refunded\')
              GROUP BY sale_date
              ORDER BY sale_date',
            ['from' => $from, 'to' => $to],
        )->toArray();
    }

    /**
     * Top-selling items for a date range.
     *
     * @return list<array<string, mixed>>
     */
    public function topItems(string $from, string $to, int $limit = 20): array
    {
        return $this->conn->select(
            'SELECT sl.sku, sl.description,
                    COALESCE(sum(sl.quantity), 0)        AS quantity,
                    COALESCE(sum(sl.extended_price), 0)  AS revenue
               FROM sale_line sl
               JOIN sale s ON s.id = sl.sale_id
              WHERE s.sale_date BETWEEN :from AND :to
                AND s.status IN (\'completed\', \'partially_refunded\', \'refunded\')
              GROUP BY sl.sku, sl.description
              ORDER BY revenue DESC
              LIMIT :limit',
            ['from' => $from, 'to' => $to, 'limit' => $limit],
        )->toArray();
    }

    /**
     * Realtime vendor balances (from the vendor portal view, ADR-0028).
     *
     * @return list<array<string, mixed>>
     */
    public function vendorBalances(): array
    {
        return $this->conn->select('SELECT * FROM v_vendor_balance_realtime')->toArray();
    }

    /**
     * A single vendor's realtime balance.
     *
     * @return array<string, mixed>|null
     */
    public function vendorBalance(string $partyId): ?array
    {
        $row = $this->conn->select(
            'SELECT * FROM v_vendor_balance_realtime WHERE party_id = :party',
            ['party' => $partyId],
        )->first();

        return $row?->toArray();
    }

    /**
     * Inventory valuation (owned stock at moving weighted average, ADR-0031).
     *
     * @return array<string, mixed>
     */
    public function inventoryValuation(string $currency = 'USD'): array
    {
        return $this->conn->selectOne(
            'SELECT
                count(*) FILTER (WHERE is_active)          AS active_items,
                COALESCE(sum(on_hand), 0)                  AS units_on_hand,
                COALESCE(sum(on_hand * avg_cost), 0)       AS total_value
               FROM inventory_item
              WHERE currency = :currency',
            ['currency' => $currency],
        )->toArray();
    }

    /**
     * Tax collected by jurisdiction for a date range.
     *
     * @return list<array<string, mixed>>
     */
    public function taxCollected(string $from, string $to): array
    {
        return $this->conn->select(
            'SELECT tj.code AS jurisdiction, tj.name,
                    COALESCE(sum(slt.tax_amount), 0) AS tax_collected
               FROM sale_line_tax slt
               JOIN sale_line sl ON sl.id = slt.sale_line_id
               JOIN sale s ON s.id = sl.sale_id
               JOIN tax_jurisdiction tj ON tj.id = slt.jurisdiction_id
              WHERE s.sale_date BETWEEN :from AND :to
                AND s.status IN (\'completed\', \'partially_refunded\', \'refunded\')
              GROUP BY tj.code, tj.name
              ORDER BY tax_collected DESC',
            ['from' => $from, 'to' => $to],
        )->toArray();
    }
}
