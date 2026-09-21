<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Pos;

use InvalidArgumentException;

/**
 * Everything needed to ring up and post a sale.
 *
 * @phpstan-type LineList list<SaleLineInput>
 * @phpstan-type TenderList list<TenderInput>
 */
final class SaleRequest
{
    /**
     * @param list<SaleLineInput> $lines
     * @param list<TenderInput>   $tenders
     */
    public function __construct(
        public readonly array $lines,
        public readonly array $tenders,
        public readonly string $currency = 'USD',
        public readonly ?string $registerId = null,
        public readonly ?string $shiftId = null,
        public readonly ?string $customerPartyId = null,
        public readonly string $channel = 'in_store',
        public readonly ?string $saleDate = null,
        public readonly ?string $idempotencyKey = null,
    ) {
        if ($this->lines === []) {
            throw new InvalidArgumentException('A sale needs at least one line.');
        }
        if ($this->tenders === []) {
            throw new InvalidArgumentException('A sale needs at least one tender.');
        }
        if (!in_array($channel, ['in_store', 'online', 'phone', 'event'], true)) {
            throw new InvalidArgumentException(sprintf('Unknown sale channel: "%s".', $channel));
        }
    }
}
