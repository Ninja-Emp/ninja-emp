<?php

declare(strict_types=1);

namespace NinjaEMP\Ledger;

use NinjaEMP\Db\Sql\Value;

use NinjaEMP\Db\Connection;

/**
 * The ledger engine (ADR-0020 / ADR-0028 / ADR-0029).
 *
 * Append-only, reversal-not-edit, idempotent. Account determination goes through
 * posting_map — no hard-coded account numbers. All work runs inside a transaction
 * so SET LOCAL tenant context is applied and the deferred balance trigger fires
 * at COMMIT.
 */
final class LedgerService
{
    public function __construct(private readonly Connection $db)
    {
    }

    /**
     * Post a balanced entry. Idempotent: the same idempotency key returns the same
     * entry id (proven by invariant T2).
     *
     * @return string the journal entry uuid
     */
    public function post(JournalEntry $entry): string
    {
        return (string) $this->db->transactional(function () use ($entry): string {
            $lines = [];

            foreach ($entry->lines as $line) {
                $accountId = $line->accountId ?? $this->resolveAccount(Value::str($line->accountRole));
                $lines[] = $line->toArray($accountId);
            }

            return $this->db->scalarString(
                'SELECT post_journal_entry(:date, :memo, :source, :ref, :key, :lines)',
                [
                    'date' => $entry->entryDate,
                    'memo' => $entry->memo,
                    'source' => $entry->source,
                    'ref' => $entry->sourceRef,
                    'key' => $entry->idempotencyKey,
                    'lines' => json_encode($lines, JSON_THROW_ON_ERROR),
                ],
            );
        });
    }

    /**
     * Reverse an entry by posting a mirror entry linked via reversal_of_id.
     * The original is never edited.
     */
    public function reverse(string $entryId, string $reversalDate, ?string $memo = null, ?string $idempotencyKey = null): string
    {
        return (string) $this->db->transactional(fn (): string => $this->db->scalarString(
            'SELECT reverse_journal_entry(:entry, :date, :memo, :key)',
            [
                'entry' => $entryId,
                'date' => $reversalDate,
                'memo' => $memo,
                'key' => $idempotencyKey,
            ],
        ));
    }

    /**
     * Resolve a posting role to its account id via posting_map (ADR-0020).
     * Raises a ConstraintViolationException when the role is unmapped.
     */
    public function resolveAccount(string $roleCode): string
    {
        return $this->db->scalarString('SELECT posting_account(:role)', ['role' => $roleCode]);
    }
}
