<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Pos;

use InvalidArgumentException;

/**
 * One tender within a payment (ADR-0029: split tenders are first-class).
 *
 * Liability tenders (store credit, gift certificate, vendor draw) must identify
 * the party whose balance is being drawn down — the ledger tags the line to that
 * party's subledger. Cash and card tenders carry no party.
 */
final class TenderInput
{
    /** Tenders that extinguish a liability and therefore require a party. */
    private const LIABILITY = ['store_credit', 'gift_cert', 'vendor_draw'];

    public function __construct(
        public readonly string $code,
        public readonly string $amount,
        public readonly ?string $partyId = null,
        public readonly ?string $cardLast4 = null,
        public readonly ?string $processorRef = null,
    ) {
        if ($amount === '' || preg_match('/^\d+(\.\d+)?$/', $amount) !== 1) {
            throw new InvalidArgumentException(sprintf('Malformed tender amount: "%s".', $amount));
        }

        if (in_array($code, self::LIABILITY, true) && $partyId === null) {
            throw new InvalidArgumentException(sprintf('Tender "%s" requires a party id.', $code));
        }
    }

    public function isLiability(): bool
    {
        return in_array($this->code, self::LIABILITY, true);
    }
}
