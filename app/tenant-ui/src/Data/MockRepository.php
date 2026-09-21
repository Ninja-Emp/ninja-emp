<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Data;

/**
 * Thin mock data layer.
 *
 * This is the ONLY place that knows where data comes from. To wire the real
 * application, replace the bodies of these methods with DBAL calls against the
 * tenant schema (and the v_vendor_* views). Controllers and views never change.
 */
final class MockRepository
{
    /** @var array<string,mixed> */
    private array $data;

    public function __construct()
    {
        $this->data = require __DIR__ . '/seed.php';
    }

    public function tenant(): array
    {
        return $this->data['tenant'];
    }

    /** @return list<array<string,mixed>> */
    public function spaces(): array
    {
        return $this->data['spaces'];
    }

    public function space(string $id): ?array
    {
        foreach ($this->data['spaces'] as $space) {
            if ($space['id'] === $id) {
                return $space;
            }
        }
        return null;
    }

    /** @return list<array<string,mixed>> */
    public function vendors(): array
    {
        return $this->data['vendors'];
    }

    public function vendor(string $id): ?array
    {
        foreach ($this->data['vendors'] as $vendor) {
            if ($vendor['id'] === $id) {
                return $vendor;
            }
        }
        return null;
    }

    /** @return list<array<string,mixed>> */
    public function items(): array
    {
        return $this->data['items'];
    }

    public function item(string $id): ?array
    {
        foreach ($this->data['items'] as $item) {
            if ($item['id'] === $id) {
                return $item;
            }
        }
        return null;
    }

    public function itemByBarcode(string $barcode): ?array
    {
        foreach ($this->data['items'] as $item) {
            if ($item['barcode'] === $barcode || $item['sku'] === $barcode) {
                return $item;
            }
        }
        return null;
    }

    /** @return list<array<string,mixed>> */
    public function sales(): array
    {
        return $this->data['sales'];
    }

    /** @return list<array<string,mixed>> */
    public function salesTrend(): array
    {
        return $this->data['sales_trend'];
    }

    /** @return list<array<string,mixed>> */
    public function registers(): array
    {
        return $this->data['registers'];
    }

    /** @return list<array<string,mixed>> */
    public function taxRates(): array
    {
        return $this->data['tax_rates'];
    }

    // ---- Derived aggregates (would be SQL in the real app) -----------------

    /** Total sales for today as a money string. */
    public function todaySalesTotal(): string
    {
        $total = '0.0000';
        foreach ($this->data['sales'] as $sale) {
            $total = bcadd($total, $sale['total'], 4);
        }
        return $total;
    }

    /** Total owed to all vendors as a money string. */
    public function totalVendorPayable(): string
    {
        $total = '0.0000';
        foreach ($this->data['vendors'] as $vendor) {
            $total = bcadd($total, $vendor['balance'], 4);
        }
        return $total;
    }

    /** Count of items at or below their reorder point. */
    public function lowStockCount(): int
    {
        $count = 0;
        foreach ($this->data['items'] as $item) {
            if ($item['on_hand'] <= $item['reorder']) {
                $count++;
            }
        }
        return $count;
    }

    /** Total inventory value at weighted-average cost. */
    public function inventoryValue(): string
    {
        $total = '0.0000';
        foreach ($this->data['items'] as $item) {
            $total = bcadd($total, bcmul($item['cost'], (string) $item['on_hand'], 4), 4);
        }
        return $total;
    }

    /** Count of spaces by status. @return array<string,int> */
    public function spaceStatusCounts(): array
    {
        $counts = ['available' => 0, 'leased' => 0, 'reserved' => 0, 'maintenance' => 0, 'inactive' => 0];
        foreach ($this->data['spaces'] as $space) {
            $counts[$space['status']] = ($counts[$space['status']] ?? 0) + 1;
        }
        return $counts;
    }
}
