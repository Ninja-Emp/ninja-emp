<?php

declare(strict_types=1);

namespace NinjaEMP\Ledger;

use InvalidArgumentException;
use NinjaEMP\Money\Money;

/**
 * A balanced journal entry to be posted. Validates balance in PHP before it ever
 * reaches the database (the DB trigger is the backstop, not the first line of
 * defence).
 */
final class JournalEntry
{
    /** @param list<JournalLine> $lines */
    public function __construct(
        public readonly string $entryDate,
        public readonly string $memo,
        public readonly string $source,
        public readonly ?string $sourceRef,
        public readonly ?string $idempotencyKey,
        public readonly array $lines,
    ) {
        if ($this->lines === []) {
            throw new InvalidArgumentException('A journal entry needs at least one line.');
        }

        $this->assertBalanced();
    }

    /**
     * Σ debits must equal Σ credits, per currency. Cross-currency entries are
     * rejected here (FX must be resolved before posting).
     */
    private function assertBalanced(): void
    {
        /** @var array<string, Money> $debits */
        $debits = [];
        /** @var array<string, Money> $credits */
        $credits = [];

        foreach ($this->lines as $line) {
            $currency = $line->debit->currency()->code();

            $debits[$currency] ??= Money::zero($line->debit->currency());
            $credits[$currency] ??= Money::zero($line->credit->currency());

            $debits[$currency] = $debits[$currency]->plus($line->debit);
            $credits[$currency] = $credits[$currency]->plus($line->credit);
        }

        foreach ($debits as $currency => $debitTotal) {
            $creditTotal = $credits[$currency];

            if (!$debitTotal->equals($creditTotal)) {
                throw new InvalidArgumentException(\sprintf(
                    'Unbalanced journal entry in %s: debits %s ≠ credits %s.',
                    $currency,
                    $debitTotal->amount(),
                    $creditTotal->amount(),
                ));
            }
        }
    }
}
