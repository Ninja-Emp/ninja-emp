<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\VendorMall;

use InvalidArgumentException;
use NinjaEMP\Db\Connection;
use NinjaEMP\Db\Sql\Value;
use RuntimeException;

/**
 * The vendor-mall domain service.
 *
 * A vendor mall leases spaces (booths, kiosks, inline units) to vendors and bills
 * them rent. This service owns the lease documents — the lease, its space
 * allocations, its rent components, and its security deposit — and delegates the
 * ledger side to the database functions (post_rent_invoice, post_deposit_receipt).
 *
 * Space allocation is time-bounded (ADR-0021): a space may be actively leased by
 * at most one lease at a time, enforced by a partial unique index. This service
 * ends the current allocation before opening a new one so the invariant holds.
 */
final class VendorMallService
{
    public function __construct(private readonly Connection $conn)
    {
    }

    /**
     * Create a lease for a vendor (lessee) at a location.
     *
     * @return string the lease id
     */
    public function createLease(
        string $lesseePartyId,
        string $locationId,
        ?string $startDate = null,
        ?string $endDate = null,
        int $billingDay = 1,
        ?string $notes = null,
    ): string {
        if ($billingDay < 1 || $billingDay > 28) {
            throw new InvalidArgumentException('Billing day must be between 1 and 28.');
        }

        return $this->conn->transactional(function (Connection $c) use ($lesseePartyId, $locationId, $startDate, $endDate, $billingDay, $notes): string {
            $row = $c->select(
                'INSERT INTO lease
                   (lessee_party_id, location_id, status, start_date, end_date, billing_day, notes)
                 VALUES
                   (:lessee, :location, \'active\', COALESCE(:start, current_date), :end, :billing_day, :notes)
                 RETURNING id',
                [
                    'lessee' => $lesseePartyId,
                    'location' => $locationId,
                    'start' => $startDate,
                    'end' => $endDate,
                    'billing_day' => $billingDay,
                    'notes' => $notes,
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to create the lease.');
            }

            return Value::str($row->get('id'));
        });
    }

    /**
     * Allocate a space to a lease, ending any current allocation first so the
     * "one active lease per space" invariant (ADR-0021) holds.
     */
    public function allocateSpace(string $leaseId, string $spaceId, ?string $fromDate = null): void
    {
        $fromDate ??= date('Y-m-d');

        $this->conn->transactional(function (Connection $c) use ($leaseId, $spaceId, $fromDate): void {
            // End the current allocation, if any.
            $c->execute(
                'UPDATE lease_space SET thru_date = :from
                   WHERE space_id = :space AND thru_date IS NULL',
                ['from' => $fromDate, 'space' => $spaceId],
            );

            $c->execute(
                'INSERT INTO lease_space (lease_id, space_id, from_date) VALUES (:lease, :space, :from)',
                ['lease' => $leaseId, 'space' => $spaceId, 'from' => $fromDate],
            );

            $c->execute("UPDATE space SET status = 'leased' WHERE id = :id", ['id' => $spaceId]);
        });
    }

    /**
     * Add a rent component to a lease. Fixed components carry an amount;
     * percentage rent carries a rate (and optionally a breakpoint).
     */
    public function addRentComponent(
        string $leaseId,
        string $componentTypeCode,
        string $amount = '0',
        string $currency = 'USD',
        ?string $percentRate = null,
        ?string $breakpointAmount = null,
        string $billingFrequency = 'monthly',
        ?string $effectiveFrom = null,
        ?string $effectiveThru = null,
    ): string {
        if (!\in_array($billingFrequency, ['monthly', 'quarterly', 'annual'], true)) {
            throw new InvalidArgumentException(\sprintf('Unknown billing frequency: "%s".', $billingFrequency));
        }

        if ($componentTypeCode === 'percentage_rent' && $percentRate === null) {
            throw new InvalidArgumentException('Percentage rent requires a percent rate.');
        }

        return $this->conn->transactional(function (Connection $c) use ($leaseId, $componentTypeCode, $amount, $currency, $percentRate, $breakpointAmount, $billingFrequency, $effectiveFrom, $effectiveThru): string {
            $row = $c->select(
                'INSERT INTO rent_component
                   (lease_id, component_type_code, amount, currency, percent_rate, breakpoint_amount,
                    billing_frequency, effective_from, effective_thru)
                 VALUES
                   (:lease, :type, :amount, :currency, :rate, :breakpoint,
                    :frequency, COALESCE(:from, current_date), :thru)
                 RETURNING id',
                [
                    'lease' => $leaseId,
                    'type' => $componentTypeCode,
                    'amount' => $amount,
                    'currency' => $currency,
                    'rate' => $percentRate,
                    'breakpoint' => $breakpointAmount,
                    'frequency' => $billingFrequency,
                    'from' => $effectiveFrom,
                    'thru' => $effectiveThru,
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to add the rent component.');
            }

            return Value::str($row->get('id'));
        });
    }

    /**
     * Bill a lease's rent for a period. Debits AR (tagged to the lessee) and
     * credits each component's revenue account. Idempotent.
     *
     * @return string the rent invoice journal entry id
     */
    public function billRent(
        string $leaseId,
        string $periodStart,
        string $periodEnd,
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): string {
        $entryDate ??= date('Y-m-d');
        $key = $idempotencyKey ?? 'rent:' . $leaseId . ':' . $periodStart . ':' . $periodEnd;

        return $this->conn->transactional(function (Connection $c) use ($leaseId, $periodStart, $periodEnd, $entryDate, $key): string {
            $entryId = $c->scalarString('SELECT post_rent_invoice(:lease, :start, :end, :date, :key)', [
                'lease' => $leaseId,
                'start' => $periodStart,
                'end' => $periodEnd,
                'date' => $entryDate,
                'key' => $key,
            ]);

            return Value::str($entryId);
        });
    }

    /**
     * Record a security deposit for a lease: cash debit / deposit liability
     * credit, tagged to the lessee. Idempotent.
     *
     * @return string the deposit journal entry id
     */
    public function recordDeposit(
        string $leaseId,
        string $depositAmount,
        string $currency = 'USD',
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): string {
        $entryDate ??= date('Y-m-d');

        return $this->conn->transactional(function (Connection $c) use ($leaseId, $depositAmount, $currency, $entryDate, $idempotencyKey): string {
            $row = $c->select(
                'INSERT INTO lease_deposit (lease_id, deposit_amount, currency, status)
                 VALUES (:lease, :amount, :currency, \'pending\')
                 RETURNING id',
                ['lease' => $leaseId, 'amount' => $depositAmount, 'currency' => $currency],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to create the lease deposit.');
            }

            $depositId = Value::str($row->get('id'));
            $key = $idempotencyKey ?? 'deposit:' . $depositId;

            $entryId = $c->scalarString('SELECT post_deposit_receipt(:deposit, :date, :key)', [
                'deposit' => $depositId,
                'date' => $entryDate,
                'key' => $key,
            ]);

            return Value::str($entryId);
        });
    }
}
