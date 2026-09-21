<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Pos;

/**
 * The outcome of ringing up a sale: the persisted document plus the ledger entry
 * it produced. All money is a 4-dp decimal string.
 */
final class SaleResult
{
    public function __construct(
        public readonly string $saleId,
        public readonly string $saleNo,
        public readonly string $subtotal,
        public readonly string $discountTotal,
        public readonly string $taxTotal,
        public readonly string $total,
        public readonly string $currency,
        public readonly ?string $journalEntryId,
        public readonly int $inventoryLinesRelieved,
    ) {
    }
}
