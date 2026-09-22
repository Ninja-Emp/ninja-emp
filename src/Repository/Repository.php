<?php

declare(strict_types=1);

namespace NinjaEMP\Repository;

/**
 * The read/write contract the tenant UI depends on.
 *
 * This mirrors the method signatures of the prototype's MockRepository exactly,
 * so the swap from mock to real database is mechanical: controllers and views
 * never change. The real implementation (DbalRepository) maps the normalized
 * schema (party / party_role / space / inventory_item / register / sale) onto
 * the flat array shapes the UI expects.
 *
 * Money is always a string (bcmath, ADR-0002/0025) — never a float.
 */
interface Repository
{
    // ---- Tenant -----------------------------------------------------------

    /** @return array<string,mixed> */
    public function tenant(): array;

    /**
     * Update editable tenant settings (name, currency, timezone).
     *
     * @param array<string, mixed> $fields
     */
    public function updateTenant(array $fields): void;

    // ---- Spaces (booths) --------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function spaces(): array;

    /** @return array<string,mixed>|null */
    public function space(string $id): ?array;

    /**
     * Create or update a booth. Returns the space id.
     *
     * @param array<string, mixed> $fields
     */
    public function saveSpace(?string $id, array $fields): string;

    // ---- Vendors ----------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function vendors(): array;

    /** @return array<string,mixed>|null */
    public function vendor(string $id): ?array;

    /**
     * Create or update a vendor. Returns the vendor id.
     *
     * @param array<string, mixed> $fields
     */
    public function saveVendor(?string $id, array $fields): string;

    /**
     * Store buys goods from a vendor: creates a store-owned item and increases
     * what we owe the vendor (a vendor payable). Returns the new item id.
     *
     * @param array<string, mixed> $fields
     */
    public function purchaseFromVendor(string $vendorId, array $fields): string;

    // ---- Items ------------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function items(): array;

    /** @return array<string,mixed>|null */
    public function item(string $id): ?array;

    /** @return array<string,mixed>|null */
    public function itemByBarcode(string $barcode): ?array;

    /**
     * Create or update an item. Returns the item id.
     *
     * @param array<string, mixed> $fields
     */
    public function saveItem(?string $id, array $fields): string;

    // ---- Sales ------------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function sales(): array;

    /** @return list<array<string,mixed>> */
    public function salesTrend(): array;

    // ---- Registers --------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function registers(): array;

    /** @return array<string,mixed>|null */
    public function register(string $id): ?array;

    /**
     * Create or update a register. Returns the register id.
     *
     * @param array<string, mixed> $fields
     */
    public function saveRegister(?string $id, array $fields): string;

    /** Open a register with an opening float. */
    public function openRegister(string $id, string $cashier, string $float): void;

    /** Close a register with a counted drawer total; computes variance. */
    public function closeRegister(string $id, string $counted): void;

    // ---- Tax --------------------------------------------------------------

    /** @return list<array<string,mixed>> */
    public function taxRates(): array;

    // ---- Derived aggregates ----------------------------------------------

    /** Total sales for today as a money string. */
    public function todaySalesTotal(): string;

    /** Total owed to all vendors as a money string. */
    public function totalVendorPayable(): string;

    /** Count of items at or below their reorder point. */
    public function lowStockCount(): int;

    /** Total inventory value at weighted-average cost. */
    public function inventoryValue(): string;

    /**
     * Count of spaces by status.
     *
     * @return array<string, int>
     */
    public function spaceStatusCounts(): array;
}
