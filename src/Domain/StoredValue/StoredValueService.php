<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\StoredValue;

use InvalidArgumentException;
use NinjaEMP\Db\Connection;
use NinjaEMP\Db\Sql\Value;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;

/**
 * Stored value: gift certificates and store credit (ADR-0032).
 *
 * Issuing stored value creates a LIABILITY, never revenue. Revenue is recognised
 * on redemption, when goods actually change hands. Each instrument is also an
 * open item, so it ties to the GL control account exactly like AR/AP (invariant:
 * Σ instruments = GL control balance).
 *
 * Breakage is OPT-IN (tenant_config.breakage_after_months, default NULL = never).
 * Recognising it automatically is legally wrong in many US states where
 * unredeemed balances escheat rather than becoming income, so the tenant must
 * deliberately enable it.
 *
 * Posting is delegated to the database functions (issue_stored_value,
 * redeem_stored_value, recognize_breakage). This service owns the orchestration
 * and the balance reads.
 */
final class StoredValueService
{
    public const GIFT_CERTIFICATE = 'gift_certificate';
    public const STORE_CREDIT = 'store_credit';

    public function __construct(private readonly Connection $conn)
    {
    }

    /**
     * Issue a gift certificate or store credit.
     *
     * @param bool $paidWithCash true when the customer paid cash for it (debit
     *                           cash); false when it is granted (e.g. a goodwill
     *                           credit) and the offset is the configured source.
     *
     * @return string the stored value id
     */
    public function issue(
        string $instrumentKind,
        string $code,
        string $amount,
        ?string $partyId = null,
        ?string $entryDate = null,
        bool $paidWithCash = true,
        ?string $expiresDate = null,
        ?string $idempotencyKey = null,
    ): string {
        if (!\in_array($instrumentKind, [self::GIFT_CERTIFICATE, self::STORE_CREDIT], true)) {
            throw new InvalidArgumentException(\sprintf('Unknown instrument kind: "%s".', $instrumentKind));
        }

        if (trim($code) === '') {
            throw new InvalidArgumentException('A stored value code is required.');
        }

        if (!Money::of($amount, Currency::of('USD'))->isPositive()) {
            throw new InvalidArgumentException('Stored value amount must be positive.');
        }

        $entryDate ??= date('Y-m-d');

        return $this->conn->transactional(fn (): string => $this->conn->scalarString(
            'SELECT issue_stored_value(:kind, :code, :party, :amount, :date, :cash, :expires, :key)',
            [
                'kind' => $instrumentKind,
                'code' => $code,
                'party' => $partyId,
                'amount' => $amount,
                'date' => $entryDate,
                'cash' => $paidWithCash ? 'true' : 'false',
                'expires' => $expiresDate,
                'key' => $idempotencyKey,
            ],
        ));
    }

    /**
     * Redeem (draw down) an instrument. The GL side comes from the POS tender,
     * so a redemption must be linked to a sale or a journal entry.
     *
     * @return string the journal entry id
     */
    public function redeem(
        string $code,
        string $amount,
        ?string $entryDate = null,
        ?string $saleId = null,
        ?string $entryId = null,
    ): string {
        if ($saleId === null && $entryId === null) {
            throw new InvalidArgumentException(
                'A redemption must be linked to a sale or a journal entry for GL linkage.',
            );
        }

        $entryDate ??= date('Y-m-d');

        return $this->conn->transactional(fn (): string => $this->conn->scalarString(
            'SELECT redeem_stored_value(:code, :amount, :date, :sale, :entry)',
            [
                'code' => $code,
                'amount' => $amount,
                'date' => $entryDate,
                'sale' => $saleId,
                'entry' => $entryId,
            ],
        ));
    }

    /**
     * Recognise breakage as of a date. Returns null unless the tenant opted in
     * (tenant_config.breakage_after_months is set).
     */
    public function recognizeBreakage(?string $asOf = null, ?string $idempotencyKey = null): ?string
    {
        $asOf ??= date('Y-m-d');

        return $this->conn->transactional(function () use ($asOf, $idempotencyKey): ?string {
            $entry = $this->conn->scalar('SELECT recognize_breakage(:as_of, :key)', [
                'as_of' => $asOf,
                'key' => $idempotencyKey,
            ]);

            return $entry === null ? null : Value::str($entry);
        });
    }

    /**
     * Look up an instrument by code.
     *
     * @return array<string, mixed>|null
     */
    public function find(string $code): ?array
    {
        $row = $this->conn->select(
            'SELECT id, instrument_kind, code, party_id, original_amount, balance, currency,
                    issued_date, expires_date, status, open_item_id
               FROM stored_value
              WHERE code = :code AND deleted_at IS NULL',
            ['code' => $code],
        )->first();

        return $row?->toArray();
    }

    /**
     * The outstanding liability for a kind (sum of active balances).
     */
    public function outstanding(string $instrumentKind, string $currency = 'USD'): string
    {
        return $this->conn->scalarString(
            'SELECT COALESCE(sum(balance), 0)
               FROM stored_value
              WHERE instrument_kind = :kind
                AND currency = :currency
                AND status = \'active\'
                AND deleted_at IS NULL',
            ['kind' => $instrumentKind, 'currency' => $currency],
        );
    }

    /**
     * Verify instruments tie to their GL control accounts (invariant: the
     * difference must be zero). Delegates to stored_value_control_check().
     *
     * @return list<array<string, mixed>>
     */
    public function controlCheck(): array
    {
        return $this->conn->select('SELECT * FROM stored_value_control_check()')->toArray();
    }
}
