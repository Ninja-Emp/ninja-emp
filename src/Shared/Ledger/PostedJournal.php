<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

final class PostedJournal
{
    public function __construct(
        private readonly string $journalId,
        private readonly string $journalNo,
        private readonly string $postingKey,
        private readonly bool $reused,
    ) {
    }

    public function journalId(): string
    {
        return $this->journalId;
    }

    public function journalNo(): string
    {
        return $this->journalNo;
    }

    public function postingKey(): string
    {
        return $this->postingKey;
    }

    public function reused(): bool
    {
        return $this->reused;
    }
}
