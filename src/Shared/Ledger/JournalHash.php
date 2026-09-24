<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

final class JournalHash
{
    public const int SCHEME_V2 = 2;

    /**
     * @param list<array{accountCode: string, debitMinor: string, creditMinor: string, subledgerType: string|null, subledgerRef: string|null}> $lines
     */
    public static function payloadV2(
        string $postingKey,
        string $postingDate,
        string $occurredAt,
        string $periodId,
        string $journalNo,
        string $currency,
        string $sourceType,
        ?string $sourceReference,
        string $description,
        bool $isReversal,
        ?string $reversesJournalId,
        array $lines,
    ): string {
        return json_encode(
            [
                'scheme' => self::SCHEME_V2,
                'postingKey' => $postingKey,
                'postingDate' => $postingDate,
                'occurredAt' => $occurredAt,
                'periodId' => $periodId,
                'journalNo' => $journalNo,
                'currency' => $currency,
                'sourceType' => $sourceType,
                'sourceReference' => $sourceReference,
                'description' => $description,
                'isReversal' => $isReversal,
                'reversesJournalId' => $reversesJournalId,
                'lines' => $lines,
            ],
            JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_THROW_ON_ERROR,
        );
    }

    public static function hash(?string $prevHash, string $payload): string
    {
        return hash('sha256', ($prevHash ?? '') . "\n" . $payload);
    }
}
