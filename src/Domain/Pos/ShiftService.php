<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Pos;

use InvalidArgumentException;
use NinjaEMP\Db\Connection;
use NinjaEMP\Db\Sql\Value;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;
use RuntimeException;

/**
 * Register and shift (cash-drawer session) lifecycle.
 *
 * A register is a checkout station; a shift is one drawer session on it. The
 * database enforces "at most one OPEN shift per register" with a partial unique
 * index, so opening a second shift on a busy register fails loudly rather than
 * silently double-counting cash.
 *
 * Closing a shift is where over/short is booked (ADR-0029): the counted cash is
 * compared to the expected cash (opening float + cash tenders taken during the
 * shift) and the difference is posted to cash_over_short. That posting is
 * delegated to the database function post_shift_close, which is idempotent and
 * returns NULL when the drawer balances exactly (nothing to post).
 *
 * Money is a 4-dp decimal string end to end; the over/short is computed here in
 * PHP with bcmath so the caller can preview it before committing.
 */
final class ShiftService
{
    public function __construct(private readonly Connection $conn)
    {
    }

    /**
     * Create a register (checkout station).
     *
     * @return string the register id
     */
    public function createRegister(
        string $code,
        string $name,
        ?string $locationId = null,
        bool $isActive = true,
    ): string {
        if (trim($code) === '') {
            throw new InvalidArgumentException('A register code is required.');
        }

        if (trim($name) === '') {
            throw new InvalidArgumentException('A register name is required.');
        }

        return $this->conn->transactional(function (Connection $c) use ($code, $name, $locationId, $isActive): string {
            $row = $c->select(
                'INSERT INTO register (code, name, location_id, is_active)
                 VALUES (:code, :name, :location, :active)
                 RETURNING id',
                [
                    'code' => $code,
                    'name' => $name,
                    'location' => $locationId,
                    'active' => $isActive ? 'true' : 'false',
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to create the register.');
            }

            return Value::str($row->get('id'));
        });
    }

    /**
     * Open a shift on a register with an opening cash float.
     *
     * @return string the shift id
     */
    public function openShift(
        string $registerId,
        string $openingFloat = '0',
        ?string $openedByPartyId = null,
        string $currency = 'USD',
    ): string {
        $float = Money::of($openingFloat, Currency::of($currency));

        if ($float->isNegative()) {
            throw new InvalidArgumentException('An opening float cannot be negative.');
        }

        return $this->conn->transactional(function (Connection $c) use ($registerId, $float, $openedByPartyId, $currency): string {
            $row = $c->select(
                'INSERT INTO shift (register_id, opened_by_party_id, opening_float, currency, status)
                 VALUES (:register, :opened_by, :float, :currency, \'open\')
                 RETURNING id',
                [
                    'register' => $registerId,
                    'opened_by' => $openedByPartyId,
                    'float' => $float->amount(),
                    'currency' => $currency,
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to open the shift.');
            }

            return Value::str($row->get('id'));
        });
    }

    /**
     * Close a shift: record the counted cash, compute over/short, and post it.
     *
     * Returns the journal entry id, or null when the drawer balanced exactly
     * (post_shift_close returns NULL in that case — the good case).
     */
    public function closeShift(
        string $shiftId,
        string $countedCash,
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): ?string {
        $entryDate ??= date('Y-m-d');

        return $this->conn->transactional(function (Connection $c) use ($shiftId, $countedCash, $entryDate, $idempotencyKey): ?string {
            $entry = $c->scalar('SELECT post_shift_close(:shift, :counted, :date, :key)', [
                'shift' => $shiftId,
                'counted' => $countedCash,
                'date' => $entryDate,
                'key' => $idempotencyKey,
            ]);

            return $entry === null ? null : Value::str($entry);
        });
    }

    /**
     * Preview the over/short for a shift without posting anything.
     *
     * expected = opening_float + Σ cash tenders on non-refund sales in the shift.
     * over_short = counted - expected (positive = over, negative = short).
     *
     * @return array{opening_float:string, cash_in:string, expected:string, counted:string, over_short:string, currency:string}
     */
    public function previewClose(string $shiftId, string $countedCash): array
    {
        $shift = $this->conn->selectOne(
            'SELECT opening_float, currency FROM shift WHERE id = :id',
            ['id' => $shiftId],
        );

        $currency = Value::str($shift->get('currency'));
        $openingFloat = Money::of(Value::str($shift->get('opening_float')), Currency::of($currency));

        $cashIn = Money::of(
            $this->conn->scalarString(
                'SELECT COALESCE(sum(pt.amount), 0)
                   FROM sale s
                   JOIN payment p ON p.sale_id = s.id AND p.status = \'captured\'
                   JOIN payment_tender pt ON pt.payment_id = p.id
                   JOIN tender_type tt ON tt.code = pt.tender_type_code
                  WHERE s.shift_id = :shift
                    AND tt.settlement_kind = \'cash\'
                    AND NOT s.is_refund',
                ['shift' => $shiftId],
            ),
            Currency::of($currency),
        );

        $expected = $openingFloat->plus($cashIn);
        $counted = Money::of($countedCash, Currency::of($currency));
        $overShort = $counted->minus($expected);

        return [
            'opening_float' => $openingFloat->amount(),
            'cash_in' => $cashIn->amount(),
            'expected' => $expected->amount(),
            'counted' => $counted->amount(),
            'over_short' => $overShort->amount(),
            'currency' => $currency,
        ];
    }

    /**
     * The currently open shift on a register, or null.
     *
     * @return array<string, mixed>|null
     */
    public function openShiftFor(string $registerId): ?array
    {
        $row = $this->conn->select(
            'SELECT id, shift_no, opened_at, opening_float, currency
               FROM shift
              WHERE register_id = :register AND status = \'open\'
              LIMIT 1',
            ['register' => $registerId],
        )->first();

        return $row?->toArray();
    }
}
