<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

final class JournalLine
{
    public function __construct(
        private readonly string $accountCode,
        private readonly Money $debit,
        private readonly Money $credit,
        private readonly ?string $subledgerType = null,
        private readonly ?string $subledgerRef = null,
        private readonly ?string $memo = null,
    ) {
    }

    public function accountCode(): string
    {
        return $this->accountCode;
    }

    public function debit(): Money
    {
        return $this->debit;
    }

    public function credit(): Money
    {
        return $this->credit;
    }

    public function subledgerType(): ?string
    {
        return $this->subledgerType;
    }

    public function subledgerRef(): ?string
    {
        return $this->subledgerRef;
    }

    public function memo(): ?string
    {
        return $this->memo;
    }
}
