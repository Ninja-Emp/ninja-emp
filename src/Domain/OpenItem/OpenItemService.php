<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\OpenItem;

use NinjaEMP\Db\Sql\Value;

use InvalidArgumentException;
use NinjaEMP\Db\Connection;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;

/**
 * Open-item AR/AP subledger (ADR-0023).
 *
 * A running-balance subledger answers "how much is owed"; open-item accounting
 * answers "which invoices are unpaid, how old, and when did each settle" — the
 * detail required for aging, statements, collections, and cash-basis conversion
 * (ADR-0022). The GL control account remains the source of truth; open items are
 * the detail that ties to it (invariant: Σ open items = GL control balance).
 *
 * One model serves every subledger kind (ar, ap, vendor_payable,
 * customer_credit, gift_certificate, security_deposit). `open_amount` is always
 * a positive magnitude; the subledger_type_code gives direction. A credit is a
 * credit_memo document, never a negative invoice.
 *
 * Posting is delegated to the database functions (open_item_create,
 * apply_payment, write_off_open_item) so the ledger stays the single source of
 * truth. This service owns the orchestration and the FIFO/aging reads.
 */
final class OpenItemService
{
    public function __construct(private readonly Connection $conn)
    {
    }

    /**
     * Create an open item linked to a journal entry.
     *
     * A negative amount is interpreted as a credit memo of the absolute value
     * (the database does the same), so callers that compute a signed balance can
     * pass it through unchanged.
     *
     * @return string the open item id
     */
    public function create(
        string $subledgerType,
        string $partyId,
        string $source,
        string $amount,
        string $currency,
        string $issueDate,
        ?string $dueDate = null,
        ?string $sourceRef = null,
        ?string $documentNo = null,
        ?string $journalEntryId = null,
    ): string {
        if (Money::of($amount, Currency::of($currency))->isZero()) {
            throw new InvalidArgumentException('An open item of zero has nothing to settle.');
        }

        return $this->conn->transactional(fn (): string => $this->conn->scalarString(
            'SELECT open_item_create(:subledger, :party, :source, :ref, :doc, :amount, :currency, :issue, :due, :entry)',
            [
                'subledger' => $subledgerType,
                'party' => $partyId,
                'source' => $source,
                'ref' => $sourceRef,
                'doc' => $documentNo,
                'amount' => $amount,
                'currency' => $currency,
                'issue' => $issueDate,
                'due' => $dueDate,
                'entry' => $journalEntryId,
            ],
        ));
    }

    /**
     * Apply a cash settlement to a party's open items, FIFO by due date
     * (ADR-0023). The database posts the cash entry and allocates; it raises if
     * the payment exceeds what is owed.
     *
     * @return string the journal entry id
     */
    public function applyPayment(
        string $partyId,
        string $subledgerType,
        string $amount,
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): string {
        $entryDate ??= date('Y-m-d');

        return $this->conn->transactional(fn (): string => $this->conn->scalarString(
            'SELECT apply_payment(:party, :subledger, :amount, :date, :key)',
            [
                'party' => $partyId,
                'subledger' => $subledgerType,
                'amount' => $amount,
                'date' => $entryDate,
                'key' => $idempotencyKey,
            ],
        ));
    }

    /**
     * Write off an uncollectible open item (bad debt expense).
     *
     * @return string the journal entry id
     */
    public function writeOff(
        string $openItemId,
        ?string $entryDate = null,
        ?string $amount = null,
        ?string $memo = null,
        ?string $idempotencyKey = null,
    ): string {
        $entryDate ??= date('Y-m-d');

        return $this->conn->transactional(fn (): string => $this->conn->scalarString(
            'SELECT write_off_open_item(:item, :date, :amount, :memo, :key)',
            [
                'item' => $openItemId,
                'date' => $entryDate,
                'amount' => $amount,
                'memo' => $memo,
                'key' => $idempotencyKey,
            ],
        ));
    }

    /**
     * A party's open items, oldest-due first (the FIFO order settlement uses).
     *
     * @return list<array<string, mixed>>
     */
    public function openFor(string $partyId, string $subledgerType): array
    {
        return $this->conn->select(
            'SELECT id, item_kind, document_no, original_amount, open_amount, currency,
                    issue_date, due_date, status
               FROM open_item
              WHERE party_id = :party
                AND subledger_type_code = :subledger
                AND status IN (\'open\', \'partial\')
                AND deleted_at IS NULL
              ORDER BY COALESCE(due_date, issue_date), issue_date, id',
            ['party' => $partyId, 'subledger' => $subledgerType],
        )->toArray();
    }

    /**
     * Aging buckets for a subledger as of a date (current, 1-30, 31-60, 61-90,
     * 90+), summed from the open items. Returns a map bucket => amount string.
     *
     * @return array<string, string>
     */
    public function aging(string $subledgerType, ?string $asOf = null): array
    {
        $asOf ??= date('Y-m-d');

        $row = $this->conn->selectOne(
            'SELECT
                COALESCE(sum(open_amount) FILTER (WHERE :as_of::date - COALESCE(due_date, issue_date) <= 0), 0) AS current,
                COALESCE(sum(open_amount) FILTER (WHERE :as_of::date - COALESCE(due_date, issue_date) BETWEEN 1 AND 30), 0) AS d1_30,
                COALESCE(sum(open_amount) FILTER (WHERE :as_of::date - COALESCE(due_date, issue_date) BETWEEN 31 AND 60), 0) AS d31_60,
                COALESCE(sum(open_amount) FILTER (WHERE :as_of::date - COALESCE(due_date, issue_date) BETWEEN 61 AND 90), 0) AS d61_90,
                COALESCE(sum(open_amount) FILTER (WHERE :as_of::date - COALESCE(due_date, issue_date) > 90), 0) AS d90_plus
               FROM open_item
              WHERE subledger_type_code = :subledger
                AND status IN (\'open\', \'partial\')
                AND deleted_at IS NULL',
            ['as_of' => $asOf, 'subledger' => $subledgerType],
        );

        return [
            'current' => Value::str($row->get('current')),
            '1_30' => Value::str($row->get('d1_30')),
            '31_60' => Value::str($row->get('d31_60')),
            '61_90' => Value::str($row->get('d61_90')),
            '90_plus' => Value::str($row->get('d90_plus')),
        ];
    }

    /**
     * Verify the subledger ties to its GL control account (invariant: the
     * difference must be zero). Delegates to open_item_control_check().
     *
     * @return list<array<string, mixed>>
     */
    public function controlCheck(): array
    {
        return $this->conn->select('SELECT * FROM open_item_control_check()')->toArray();
    }
}
