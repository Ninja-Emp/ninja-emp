<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

final class Posting
{
    /**
     * @param list<JournalLine> $lines
     */
    public function __construct(
        private readonly string $postingKey,
        private readonly string $postingDate,
        private readonly string $occurredAt,
        private readonly string $currency,
        private readonly string $sourceType,
        private readonly string $description,
        private readonly array $lines,
        private readonly ?string $sourceReference = null,
        private readonly bool $reversal = false,
        private readonly ?string $reversesJournalId = null,
    ) {
    }

    public function postingKey(): string
    {
        return $this->postingKey;
    }

    public function postingDate(): string
    {
        return $this->postingDate;
    }

    public function occurredAt(): string
    {
        return $this->occurredAt;
    }

    public function currency(): string
    {
        return $this->currency;
    }

    public function sourceType(): string
    {
        return $this->sourceType;
    }

    public function description(): string
    {
        return $this->description;
    }

    /**
     * @return list<JournalLine>
     */
    public function lines(): array
    {
        return $this->lines;
    }

    public function sourceReference(): ?string
    {
        return $this->sourceReference;
    }

    public function reversal(): bool
    {
        return $this->reversal;
    }

    public function reversesJournalId(): ?string
    {
        return $this->reversesJournalId;
    }
}
