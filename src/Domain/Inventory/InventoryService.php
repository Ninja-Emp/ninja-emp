<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Inventory;

use InvalidArgumentException;
use NinjaEMP\Db\Connection;
use NinjaEMP\Db\Sql\Value;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;
use RuntimeException;

/**
 * The inventory domain service (ADR-0031: moving weighted-average cost).
 *
 * Owned stock is valued at moving weighted average. Receipts recompute the
 * average; issues relieve at the current average; adjustments expense the
 * difference. Consigned goods are NEVER inventory-valued — they belong to the
 * consignor until sold, at which point the payable accrues (ADR-0028).
 *
 * As with POS, the ledger side is delegated to the database's own functions
 * (receive_inventory, adjust_inventory). This service owns the item master and
 * the orchestration; it does not re-implement posting.
 */
final class InventoryService
{
    public function __construct(private readonly Connection $conn)
    {
    }

    /**
     * Create an owned inventory item (store stock).
     *
     * @return string the new item id
     */
    public function createItem(
        string $sku,
        string $description,
        string $listPrice,
        string $currency = 'USD',
        ?string $category = null,
        ?string $supplierPartyId = null,
        string $uom = 'each',
        ?string $barcode = null,
        string $reorderPoint = '0',
    ): string {
        return $this->conn->transactional(function (Connection $c) use ($sku, $description, $listPrice, $currency, $category, $supplierPartyId, $uom, $barcode, $reorderPoint): string {
            $row = $c->select(
                'INSERT INTO inventory_item
                   (sku, description, category, supplier_party_id, uom, list_price, currency,
                    reorder_point, barcode, is_active)
                 VALUES
                   (:sku, :description, :category, :supplier, :uom, :list_price, :currency,
                    :reorder, :barcode, true)
                 RETURNING id',
                [
                    'sku' => $sku,
                    'description' => $description,
                    'category' => $category,
                    'supplier' => $supplierPartyId,
                    'uom' => $uom,
                    'list_price' => $listPrice,
                    'currency' => $currency,
                    'reorder' => $reorderPoint,
                    'barcode' => $barcode,
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to create the inventory item.');
            }

            return Value::str($row->get('id'));
        });
    }

    /**
     * Receive stock against an item. Recomputes the moving weighted-average cost
     * and posts the ledger entry (inventory debit / AP or cash credit).
     *
     * @param bool $onAccount true to credit AP (supplier), false to credit cash
     *
     * @return string the receipt journal entry id
     */
    public function receive(
        string $itemId,
        string $quantity,
        string $unitCost,
        bool $onAccount = true,
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): string {
        $entryDate ??= date('Y-m-d');

        if (bccomp(Value::num($quantity), '0', 4) <= 0) {
            throw new InvalidArgumentException('Receipt quantity must be positive.');
        }

        if (bccomp(Value::num($unitCost), '0', 4) < 0) {
            throw new InvalidArgumentException('Unit cost cannot be negative.');
        }

        return $this->conn->transactional(function (Connection $c) use ($itemId, $quantity, $unitCost, $onAccount, $entryDate, $idempotencyKey): string {
            $entryId = $c->scalarString(
                'SELECT receive_inventory(:item, :qty, :cost, :date, :key, :on_account)',
                [
                    'item' => $itemId,
                    'qty' => $quantity,
                    'cost' => $unitCost,
                    'date' => $entryDate,
                    'key' => $idempotencyKey,
                    'on_account' => $onAccount ? 'true' : 'false',
                ],
            );

            return Value::str($entryId);
        });
    }

    /**
     * Adjust stock up (found) or down (shrink) at the current average cost.
     * The difference is expensed to inventory_adjustment.
     *
     * @return string the adjustment journal entry id
     */
    public function adjust(
        string $itemId,
        string $quantityDelta,
        ?string $memo = null,
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): string {
        $entryDate ??= date('Y-m-d');

        if (bccomp(Value::num($quantityDelta), '0', 4) === 0) {
            throw new InvalidArgumentException('Adjustment quantity cannot be zero.');
        }

        return $this->conn->transactional(function (Connection $c) use ($itemId, $quantityDelta, $memo, $entryDate, $idempotencyKey): string {
            $entryId = $c->scalarString(
                'SELECT adjust_inventory(:item, :delta, :date, :memo, :key)',
                [
                    'item' => $itemId,
                    'delta' => $quantityDelta,
                    'date' => $entryDate,
                    'memo' => $memo,
                    'key' => $idempotencyKey,
                ],
            );

            return Value::str($entryId);
        });
    }

    /**
     * The current on-hand quantity and moving average cost for an item.
     *
     * @return array{on_hand:string, avg_cost:string, currency:string}
     */
    public function position(string $itemId): array
    {
        return $this->conn->transactional(function (Connection $c) use ($itemId): array {
            $row = $c->select(
                'SELECT on_hand, avg_cost, currency FROM inventory_item WHERE id = :id',
                ['id' => $itemId],
            )->first();

            if ($row === null) {
                throw new InvalidArgumentException(\sprintf('No inventory item %s.', $itemId));
            }

            return [
                'on_hand' => Value::str($row->get('on_hand', '0')),
                'avg_cost' => Value::str($row->get('avg_cost', '0')),
                'currency' => Value::str($row->get('currency', 'USD')),
            ];
        });
    }

    /**
     * The total value of owned stock: Σ(on_hand × avg_cost). This is the figure
     * the Inventory GL account must equal (invariant inventory_value_check).
     */
    public function totalValue(string $currency = 'USD'): string
    {
        return $this->conn->transactional(function (Connection $c) use ($currency): string {
            $value = $c->scalarString(
                'SELECT COALESCE(sum(on_hand * avg_cost), 0)
                   FROM inventory_item
                  WHERE currency = :currency AND deleted_at IS NULL',
                ['currency' => $currency],
            );

            return Money::of(Value::str($value), Currency::of($currency))->amount();
        });
    }
}
