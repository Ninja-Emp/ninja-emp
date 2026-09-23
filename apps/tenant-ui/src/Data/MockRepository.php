<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Data;

use NinjaEMP\Db\Sql\Value;

/**
 * Thin mock data layer.
 *
 * This is the ONLY place that knows where data comes from. To wire the real
 * application, replace the bodies of these methods with DBAL calls against the
 * tenant schema (and the v_vendor_* views). Controllers and views never change.
 *
 * For the prototype the store is session-backed: it is seeded from seed.php on
 * first use, then mutations (create/update) persist for the life of the session.
 * That keeps the UI fully interactive without a database, while the method
 * signatures stay exactly what a DBAL-backed repository would expose.
 *
 * @phpstan-type Store array{
 *     tenant: array<string,mixed>,
 *     locations: list<array<string,mixed>>,
 *     floors: list<array<string,mixed>>,
 *     spaces: list<array<string,mixed>>,
 *     vendors: list<array<string,mixed>>,
 *     items: list<array<string,mixed>>,
 *     sales: list<array<string,mixed>>,
 *     sales_trend: list<array<string,mixed>>,
 *     registers: list<array<string,mixed>>,
 *     tax_rates: list<array<string,mixed>>
 * }
 */
final class MockRepository
{
    /** @var Store */
    private array $data;

    public function __construct()
    {
        if (!isset($_SESSION['nem_data']) || !\is_array($_SESSION['nem_data'])) {
            $_SESSION['nem_data'] = require __DIR__ . '/seed.php';
        }

        /** @var Store $store */
        $store = $_SESSION['nem_data'];
        $this->data = &$store;
        $_SESSION['nem_data'] = &$store;
    }

    // ---- Tenant -----------------------------------------------------------

    /** @return array<string,mixed> */
    public function tenant(): array
    {
        return $this->data['tenant'];
    }

    /**
     * Update editable tenant settings (name, currency, timezone).
     *
     * @param array<string,mixed> $fields
     */
    public function updateTenant(array $fields): void
    {
        foreach (['name', 'currency', 'timezone'] as $key) {
            if (isset($fields[$key]) && $fields[$key] !== '') {
                $this->data['tenant'][$key] = $fields[$key];
            }
        }
    }

    // ---- Spaces (booths) --------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function spaces(): array
    {
        return $this->data['spaces'];
    }

    /** @return array<string,mixed>|null */
    public function space(string $id): ?array
    {
        foreach ($this->data['spaces'] as $space) {
            if ($space['id'] === $id) {
                return $space;
            }
        }

        return null;
    }

    /**
     * Create or update a booth. Returns the space id.
     *
     * @param array<string,mixed> $fields
     */
    public function saveSpace(?string $id, array $fields): string
    {
        if ($id !== null && ($i = $this->indexOf('spaces', $id)) !== null) {
            $this->data['spaces'][$i] = array_merge($this->data['spaces'][$i], $fields);

            return $id;
        }
        $id = $this->nextId('spaces', 'sp-');
        $this->data['spaces'][] = array_merge([
            'id' => $id, 'floor_id' => 'flr-1', 'type' => 'inline', 'sqft' => 0,
            'status' => 'available', 'vendor_id' => null, 'rent' => '0.0000',
            'x' => 1, 'y' => 1, 'w' => 1, 'h' => 1,
        ], $fields, ['id' => $id]);

        return $id;
    }

    // ---- Vendors ----------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function vendors(): array
    {
        return $this->data['vendors'];
    }

    /** @return array<string,mixed>|null */
    public function vendor(string $id): ?array
    {
        foreach ($this->data['vendors'] as $vendor) {
            if ($vendor['id'] === $id) {
                return $vendor;
            }
        }

        return null;
    }

    /**
     * Create or update a vendor. Returns the vendor id.
     *
     * @param array<string,mixed> $fields
     */
    public function saveVendor(?string $id, array $fields): string
    {
        if ($id !== null && ($i = $this->indexOf('vendors', $id)) !== null) {
            $this->data['vendors'][$i] = array_merge($this->data['vendors'][$i], $fields);

            return $id;
        }
        $id = $this->nextId('vendors', 'v-');
        $this->data['vendors'][] = array_merge([
            'id' => $id, 'contact' => '', 'email' => '', 'phone' => '',
            'type' => 'consignor', 'commission' => '20.0000', 'balance' => '0.0000',
            'status' => 'active', 'since' => date('Y-m-d'),
        ], $fields, ['id' => $id]);

        return $id;
    }

    /**
     * Store buys goods from a vendor: creates a store-owned item and increases
     * what we owe the vendor (a vendor payable). Returns the new item id.
     *
     * @param array<string,mixed> $fields
     */
    public function purchaseFromVendor(string $vendorId, array $fields): string
    {
        $qty = max(1, Value::int($fields['qty'] ?? 1));
        $cost = Value::num($fields['cost'] ?? '0.0000');
        $itemId = $this->saveItem(null, [
            'name'      => $fields['name'] ?? 'Purchased item',
            'sku'       => $fields['sku'] ?? '',
            'barcode'   => $fields['barcode'] ?? '',
            'category'  => $fields['category'] ?? 'General',
            'price'     => $fields['price'] ?? $cost,
            'cost'      => $cost,
            'on_hand'   => $qty,
            'reorder'   => 0,
            'owner'     => 'store',
            'vendor_id' => null,
            'source_vendor_id' => $vendorId,
        ]);

        // Increase the vendor payable by cost * qty.
        if (($i = $this->indexOf('vendors', $vendorId)) !== null) {
            $owed = bcmul($cost, (string) $qty, 4);
            $balance = Value::num($this->data['vendors'][$i]['balance']);
            $this->data['vendors'][$i]['balance'] = bcadd($balance, $owed, 4);
        }

        return $itemId;
    }

    // ---- Items ------------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function items(): array
    {
        return $this->data['items'];
    }

    /** @return array<string,mixed>|null */
    public function item(string $id): ?array
    {
        foreach ($this->data['items'] as $item) {
            if ($item['id'] === $id) {
                return $item;
            }
        }

        return null;
    }

    /** @return array<string,mixed>|null */
    public function itemByBarcode(string $barcode): ?array
    {
        foreach ($this->data['items'] as $item) {
            if ($item['barcode'] === $barcode || $item['sku'] === $barcode) {
                return $item;
            }
        }

        return null;
    }

    /**
     * Create or update an item. Returns the item id.
     *
     * @param array<string,mixed> $fields
     */
    public function saveItem(?string $id, array $fields): string
    {
        if ($id !== null && ($i = $this->indexOf('items', $id)) !== null) {
            $this->data['items'][$i] = array_merge($this->data['items'][$i], $fields);

            return $id;
        }
        $id = $this->nextId('items', 'it-');
        $this->data['items'][] = array_merge([
            'id' => $id, 'sku' => '', 'name' => '', 'vendor_id' => null,
            'category' => 'General', 'price' => '0.0000', 'cost' => '0.0000',
            'on_hand' => 0, 'reorder' => 0, 'barcode' => '', 'owner' => 'vendor',
        ], $fields, ['id' => $id]);

        return $id;
    }

    // ---- Sales ------------------------------------------------------------

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

    // ---- Registers --------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function registers(): array
    {
        return $this->data['registers'];
    }

    /** @return array<string,mixed>|null */
    public function register(string $id): ?array
    {
        foreach ($this->data['registers'] as $reg) {
            if ($reg['id'] === $id) {
                return $reg;
            }
        }

        return null;
    }

    /**
     * Create or update a register. Returns the register id.
     *
     * @param array<string,mixed> $fields
     */
    public function saveRegister(?string $id, array $fields): string
    {
        if ($id !== null && ($i = $this->indexOf('registers', $id)) !== null) {
            $this->data['registers'][$i] = array_merge($this->data['registers'][$i], $fields);

            return $id;
        }
        $id = $this->nextId('registers', 'reg-');
        $this->data['registers'][] = array_merge([
            'id' => $id, 'name' => 'Register', 'status' => 'closed',
            'cashier' => null, 'opened' => null, 'drawer' => '0.0000',
            'float' => '0.0000', 'counted' => null, 'variance' => null,
        ], $fields, ['id' => $id]);

        return $id;
    }

    /** Open a register with an opening float. */
    public function openRegister(string $id, string $cashier, string $float): void
    {
        if (($i = $this->indexOf('registers', $id)) === null) {
            return;
        }
        $this->data['registers'][$i]['status'] = 'open';
        $this->data['registers'][$i]['cashier'] = $cashier;
        $this->data['registers'][$i]['opened'] = date('H:i');
        $this->data['registers'][$i]['float'] = $float;
        $this->data['registers'][$i]['drawer'] = $float;
        $this->data['registers'][$i]['counted'] = null;
        $this->data['registers'][$i]['variance'] = null;
    }

    /** Close a register with a counted drawer total; computes variance. */
    public function closeRegister(string $id, string $counted): void
    {
        if (($i = $this->indexOf('registers', $id)) === null) {
            return;
        }
        $expected = Value::num($this->data['registers'][$i]['drawer'] ?? '0.0000');
        $this->data['registers'][$i]['status'] = 'closed';
        $this->data['registers'][$i]['counted'] = $counted;
        $this->data['registers'][$i]['variance'] = bcsub(Value::num($counted), $expected, 4);
        $this->data['registers'][$i]['cashier'] = null;
        $this->data['registers'][$i]['opened'] = null;
    }

    // ---- Tax --------------------------------------------------------------

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
            $total = bcadd($total, Value::num($sale['total']), 4);
        }

        return $total;
    }

    /** Total owed to all vendors as a money string. */
    public function totalVendorPayable(): string
    {
        $total = '0.0000';

        foreach ($this->data['vendors'] as $vendor) {
            $total = bcadd($total, Value::num($vendor['balance']), 4);
        }

        return $total;
    }

    /** Count of items at or below their reorder point. */
    public function lowStockCount(): int
    {
        $count = 0;

        foreach ($this->data['items'] as $item) {
            if (bccomp(Value::num($item['on_hand']), Value::num($item['reorder']), 4) <= 0) {
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
            $total = bcadd($total, bcmul(Value::num($item['cost']), Value::num($item['on_hand']), 4), 4);
        }

        return $total;
    }

    /**
     * Count of spaces by status.
     *
     * @return array<string,int>
     */
    public function spaceStatusCounts(): array
    {
        $counts = ['available' => 0, 'leased' => 0, 'reserved' => 0, 'maintenance' => 0, 'inactive' => 0];

        foreach ($this->data['spaces'] as $space) {
            $status = Value::str($space['status']);
            $counts[$status] = ($counts[$status] ?? 0) + 1;
        }

        return $counts;
    }

    // ---- Internals --------------------------------------------------------

    /**
     * Find the array index of a record by id, or null.
     *
     * @param 'spaces'|'vendors'|'items'|'registers' $collection
     */
    private function indexOf(string $collection, string $id): ?int
    {
        foreach ($this->data[$collection] as $i => $row) {
            if (($row['id'] ?? null) === $id) {
                return $i;
            }
        }

        return null;
    }

    /**
     * Generate the next sequential id for a collection (e.g. it-13).
     *
     * @param 'spaces'|'vendors'|'items'|'registers' $collection
     */
    private function nextId(string $collection, string $prefix): string
    {
        $max = 0;

        foreach ($this->data[$collection] as $row) {
            if (preg_match('/^' . preg_quote($prefix, '/') . '(\d+)$/', Value::str($row['id'] ?? ''), $m) === 1) {
                $max = max($max, (int) $m[1]);
            }
        }

        return $prefix . ($max + 1);
    }
}
