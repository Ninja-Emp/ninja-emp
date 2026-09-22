<?php

declare(strict_types=1);

namespace NinjaEMP\Ledger;

use NinjaEMP\Db\Sql\Value;

use InvalidArgumentException;
use NinjaEMP\Money\Money;

/**
 * One line of a journal entry. Debit XOR credit; amounts are never negative
 * (mirrors the journal_line CHECK constraints).
 *
 * A line is addressed either by a resolved account id (uuid) or by a posting
 * role code that the LedgerService resolves through posting_map (ADR-0020).
 */
final class JournalLine
{
    private function __construct(
        public readonly ?string $accountId,
        public readonly ?string $accountRole,
        public readonly Money $debit,
        public readonly Money $credit,
        public readonly ?string $partyId = null,
        public readonly ?string $subledgerTypeCode = null,
        public readonly ?string $memo = null,
    ) {
        if ($this->accountId === null && $this->accountRole === null) {
            throw new InvalidArgumentException('A journal line needs an account id or a posting role.');
        }

        if ($this->debit->isNegative() || $this->credit->isNegative()) {
            throw new InvalidArgumentException('Journal line amounts must not be negative.');
        }

        $hasDebit = $this->debit->isPositive();
        $hasCredit = $this->credit->isPositive();

        if ($hasDebit === $hasCredit) {
            throw new InvalidArgumentException('A journal line must be either a debit or a credit, not both/neither.');
        }

        if (($this->partyId === null) !== ($this->subledgerTypeCode === null)) {
            throw new InvalidArgumentException('Subledger tagging is all-or-nothing: party_id and subledger_type_code go together.');
        }
    }

    public static function debit(string $accountRole, Money $amount, ?string $partyId = null, ?string $subledgerTypeCode = null, ?string $memo = null): self
    {
        return new self(null, $accountRole, $amount, Money::zero($amount->currency()), $partyId, $subledgerTypeCode, $memo);
    }

    public static function credit(string $accountRole, Money $amount, ?string $partyId = null, ?string $subledgerTypeCode = null, ?string $memo = null): self
    {
        return new self(null, $accountRole, Money::zero($amount->currency()), $amount, $partyId, $subledgerTypeCode, $memo);
    }

    public static function debitAccount(string $accountId, Money $amount, ?string $partyId = null, ?string $subledgerTypeCode = null, ?string $memo = null): self
    {
        return new self($accountId, null, $amount, Money::zero($amount->currency()), $partyId, $subledgerTypeCode, $memo);
    }

    public static function creditAccount(string $accountId, Money $amount, ?string $partyId = null, ?string $subledgerTypeCode = null, ?string $memo = null): self
    {
        return new self($accountId, null, Money::zero($amount->currency()), $amount, $partyId, $subledgerTypeCode, $memo);
    }

    /**
     * Serialise to the jsonb shape post_journal_entry() expects.
     *
     * @return array<string, string>
     */
    public function toArray(string $resolvedAccountId): array
    {
        $line = [
            'account_id' => $resolvedAccountId,
            'debit' => $this->debit->amount(),
            'credit' => $this->credit->amount(),
            'currency' => $this->debit->currency()->code(),
        ];

        if ($this->partyId !== null) {
            $line['party_id'] = $this->partyId;
            $line['subledger_type_code'] = Value::str($this->subledgerTypeCode);
        }

        if ($this->memo !== null) {
            $line['memo'] = $this->memo;
        }

        return $line;
    }
}
