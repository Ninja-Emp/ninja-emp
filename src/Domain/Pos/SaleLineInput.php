<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Pos;

use InvalidArgumentException;

/**
 * One line to ring up at the register.
 *
 * A line is either:
 *   - 'consignment' — a consigned item; the store keeps a commission and owes the
 *     consignor the rest (ADR-0028: the payable accrues AT SALE). Requires a
 *     consignor and a commission rate.
 *   - 'owned' — store-owned stock; the store keeps the whole margin and relieves
 *     inventory at moving weighted-average cost (ADR-0031). Requires an
 *     inventory item.
 *
 * Money and quantity are decimal strings (never floats). The service computes the
 * extended price, the commission split, and the totals; this object only carries
 * the operator's intent.
 */
final class SaleLineInput
{
    public const CONSIGNMENT = 'consignment';
    public const OWNED = 'owned';

    public function __construct(
        public readonly string $kind,
        public readonly string $description,
        public readonly string $quantity = '1',
        public readonly string $unitPrice = '0',
        public readonly string $discountAmount = '0',
        public readonly ?string $commissionRate = null,
        public readonly ?string $consignorPartyId = null,
        public readonly ?string $consignmentItemId = null,
        public readonly ?string $inventoryItemId = null,
        public readonly ?string $vendorPartyId = null,
        public readonly ?string $sku = null,
        public readonly ?string $unitCost = null,
        public readonly bool $isTaxable = true,
        public readonly string $taxAmount = '0',
    ) {
        if (!\in_array($kind, [self::CONSIGNMENT, self::OWNED], true)) {
            throw new InvalidArgumentException(\sprintf('Unknown sale line kind: "%s".', $kind));
        }

        if ($kind === self::CONSIGNMENT) {
            if ($consignorPartyId === null) {
                throw new InvalidArgumentException('A consignment line requires a consignor party id.');
            }

            if ($commissionRate === null) {
                throw new InvalidArgumentException('A consignment line requires a commission rate.');
            }
        }

        if ($kind === self::OWNED && $inventoryItemId === null) {
            throw new InvalidArgumentException('An owned line requires an inventory item id.');
        }
    }

    public function isConsignment(): bool
    {
        return $this->kind === self::CONSIGNMENT;
    }
}
