<?php

declare(strict_types=1);

namespace NinjaEMP\Domain\Consignment;

use InvalidArgumentException;
use NinjaEMP\Db\Connection;
use NinjaEMP\Db\Sql\Value;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;
use RuntimeException;

/**
 * The consignment domain service.
 *
 * A consignor places goods with the store; the store sells them and keeps a
 * commission, owing the consignor the rest. Per ADR-0028 the consignor payable
 * accrues AT SALE — not at settlement — so the vendor portal reads realtime
 * numbers straight from the ledger.
 *
 * The commission split is exact by construction: net_to_consignor is the
 * remainder after the commission, so commission + net always equals the sale
 * price to the last unit (the DB CHECK enforces the same identity).
 *
 * Ledger posting is delegated to the database functions (post_consignment_sale,
 * post_consignor_payout). This service owns the documents and the orchestration.
 */
final class ConsignmentService
{
    public function __construct(private readonly Connection $conn)
    {
    }

    /**
     * Open a consignor agreement.
     *
     * @return string the agreement id
     */
    public function createAgreement(
        string $consignorPartyId,
        string $defaultCommissionRate = '0.40',
        string $settlementFrequency = 'monthly',
        ?string $startDate = null,
        ?string $notes = null,
    ): string {
        if (bccomp(Value::num($defaultCommissionRate), '0', 6) < 0 || bccomp(Value::num($defaultCommissionRate), '1', 6) > 0) {
            throw new InvalidArgumentException('Commission rate must be between 0 and 1.');
        }

        if (!\in_array($settlementFrequency, ['on_demand', 'weekly', 'biweekly', 'monthly'], true)) {
            throw new InvalidArgumentException(\sprintf('Unknown settlement frequency: "%s".', $settlementFrequency));
        }

        return $this->conn->transactional(function (Connection $c) use ($consignorPartyId, $defaultCommissionRate, $settlementFrequency, $startDate, $notes): string {
            $row = $c->select(
                'INSERT INTO consignor_agreement
                   (consignor_party_id, default_commission_rate, settlement_frequency, start_date, notes, status)
                 VALUES (:party, :rate, :freq, COALESCE(:start, current_date), :notes, \'active\')
                 RETURNING id',
                [
                    'party' => $consignorPartyId,
                    'rate' => $defaultCommissionRate,
                    'freq' => $settlementFrequency,
                    'start' => $startDate,
                    'notes' => $notes,
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to create the consignor agreement.');
            }

            return Value::str($row->get('id'));
        });
    }

    /**
     * Receive a consigned item onto the floor.
     *
     * @return string the consignment item id
     */
    public function receiveItem(
        string $agreementId,
        string $description,
        string $agreedPrice,
        string $currency = 'USD',
        ?string $sku = null,
        ?string $category = null,
        ?string $condition = null,
        ?string $barcode = null,
        ?string $receivedDate = null,
    ): string {
        return $this->conn->transactional(function (Connection $c) use ($agreementId, $description, $agreedPrice, $currency, $sku, $category, $condition, $barcode, $receivedDate): string {
            $row = $c->select(
                'INSERT INTO consignment_item
                   (agreement_id, sku, description, category, condition, agreed_price, currency,
                    barcode, received_date, status)
                 VALUES
                   (:agreement, :sku, :description, :category, :condition, :price, :currency,
                    :barcode, COALESCE(:received, current_date), \'available\')
                 RETURNING id',
                [
                    'agreement' => $agreementId,
                    'sku' => $sku,
                    'description' => $description,
                    'category' => $category,
                    'condition' => $condition,
                    'price' => $agreedPrice,
                    'currency' => $currency,
                    'barcode' => $barcode,
                    'received' => $receivedDate,
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to receive the consigned item.');
            }

            return Value::str($row->get('id'));
        });
    }

    /**
     * Change an item's price, recording the history (append-only detail).
     */
    public function changePrice(string $itemId, string $newPrice, ?string $reason = null): void
    {
        $this->conn->transactional(function (Connection $c) use ($itemId, $newPrice, $reason): void {
            $current = $c->select('SELECT agreed_price FROM consignment_item WHERE id = :id', ['id' => $itemId])->first();

            if ($current === null) {
                throw new InvalidArgumentException(\sprintf('No consignment item %s.', $itemId));
            }

            $c->execute(
                'INSERT INTO item_price_change (item_id, old_price, new_price, reason)
                 VALUES (:item, :old, :new, :reason)',
                [
                    'item' => $itemId,
                    'old' => Value::str($current->get('agreed_price')),
                    'new' => $newPrice,
                    'reason' => $reason,
                ],
            );

            $c->execute('UPDATE consignment_item SET agreed_price = :price WHERE id = :id', [
                'price' => $newPrice,
                'id' => $itemId,
            ]);
        });
    }

    /**
     * Record a consignment sale and post it. Each line carries the item, the
     * price, the commission split, and the consignor. The consignor payable
     * accrues immediately (ADR-0028).
     *
     * @param list<array{itemId:string, consignorPartyId:string, salePrice:string, commissionRate:string}> $lines
     *
     * @return array{saleId:string, saleNo:string, journalEntryId:string, gross:string, net:string}
     */
    public function recordSale(
        array $lines,
        string $currency = 'USD',
        ?string $customerPartyId = null,
        string $channel = 'store',
        ?string $saleDate = null,
        ?string $idempotencyKey = null,
    ): array {
        if ($lines === []) {
            throw new InvalidArgumentException('A consignment sale needs at least one line.');
        }

        if (!\in_array($channel, ['store', 'online', 'event', 'other'], true)) {
            throw new InvalidArgumentException(\sprintf('Unknown consignment channel: "%s".', $channel));
        }

        $saleDate ??= date('Y-m-d');
        $ccy = Currency::of($currency);

        return $this->conn->transactional(function (Connection $c) use ($lines, $currency, $ccy, $customerPartyId, $channel, $saleDate, $idempotencyKey): array {
            $gross = Money::zero($ccy);
            $net = Money::zero($ccy);

            $saleRow = $c->select(
                'INSERT INTO consignment_sale (sale_date, channel, customer_party_id, status)
                 VALUES (:date, :channel, :customer, \'completed\')
                 RETURNING id, sale_no',
                ['date' => $saleDate, 'channel' => $channel, 'customer' => $customerPartyId],
            )->first();

            if ($saleRow === null) {
                throw new RuntimeException('Failed to insert the consignment sale.');
            }

            $saleId = Value::str($saleRow->get('id'));
            $saleNo = Value::str($saleRow->get('sale_no'));

            foreach ($lines as $line) {
                $price = Money::of($line['salePrice'], $ccy);
                $commission = $price->times($line['commissionRate']);
                $lineNet = $price->minus($commission); // exact remainder

                $c->execute(
                    'INSERT INTO consignment_sale_line
                       (sale_id, item_id, consignor_party_id, sale_price, commission_rate,
                        commission_amount, net_to_consignor, currency)
                     VALUES
                       (:sale, :item, :consignor, :price, :rate, :commission, :net, :currency)',
                    [
                        'sale' => $saleId,
                        'item' => $line['itemId'],
                        'consignor' => $line['consignorPartyId'],
                        'price' => $price->amount(),
                        'rate' => $line['commissionRate'],
                        'commission' => $commission->amount(),
                        'net' => $lineNet->amount(),
                        'currency' => $currency,
                    ],
                );

                // The item is now sold — off the floor.
                $c->execute("UPDATE consignment_item SET status = 'sold' WHERE id = :id", ['id' => $line['itemId']]);

                $gross = $gross->plus($price);
                $net = $net->plus($lineNet);
            }

            $key = $idempotencyKey ?? 'consignment_sale:' . $saleId;
            $entryId = $c->scalarString('SELECT post_consignment_sale(:sale, :date, :key)', [
                'sale' => $saleId,
                'date' => $saleDate,
                'key' => $key,
            ]);

            return [
                'saleId' => $saleId,
                'saleNo' => $saleNo,
                'journalEntryId' => Value::str($entryId),
                'gross' => $gross->amount(),
                'net' => $net->amount(),
            ];
        });
    }

    /**
     * Build a settlement batch for a consignor over a period from their sold
     * lines, then pay it out. Returns the payout journal entry id.
     *
     * @return array{settlementId:string, payoutId:string, journalEntryId:string, netPayable:string}
     */
    public function settleAndPay(
        string $consignorPartyId,
        string $periodStart,
        string $periodEnd,
        string $currency = 'USD',
        string $method = 'cash',
        ?string $payoutDate = null,
        ?string $idempotencyKey = null,
    ): array {
        if (!\in_array($method, ['cash', 'check', 'ach', 'store_credit', 'other'], true)) {
            throw new InvalidArgumentException(\sprintf('Unknown payout method: "%s".', $method));
        }

        $payoutDate ??= date('Y-m-d');
        $ccy = Currency::of($currency);

        return $this->conn->transactional(function (Connection $c) use ($consignorPartyId, $periodStart, $periodEnd, $currency, $ccy, $method, $payoutDate, $idempotencyKey): array {
            // Gather the consignor's sold lines in the period.
            $rows = $c->select(
                'SELECT csl.id, csl.sale_price, csl.commission_amount, csl.net_to_consignor
                   FROM consignment_sale_line csl
                   JOIN consignment_sale cs ON cs.id = csl.sale_id
                  WHERE csl.consignor_party_id = :party
                    AND cs.sale_date BETWEEN :start AND :end
                    AND cs.status = \'completed\'',
                ['party' => $consignorPartyId, 'start' => $periodStart, 'end' => $periodEnd],
            );

            if ($rows->isEmpty()) {
                throw new InvalidArgumentException('No sold consignment lines for that consignor in the period.');
            }

            $gross = Money::zero($ccy);
            $commission = Money::zero($ccy);
            $net = Money::zero($ccy);
            /** @var list<array<string,string>> $lines */
            $lines = [];

            foreach ($rows as $row) {
                $g = Money::of(Value::str($row->get('sale_price')), $ccy);
                $cm = Money::of(Value::str($row->get('commission_amount')), $ccy);
                $n = Money::of(Value::str($row->get('net_to_consignor')), $ccy);
                $gross = $gross->plus($g);
                $commission = $commission->plus($cm);
                $net = $net->plus($n);
                $lines[] = [
                    'sale_line_id' => Value::str($row->get('id')),
                    'gross' => $g->amount(),
                    'commission' => $cm->amount(),
                    'net' => $n->amount(),
                ];
            }

            $settlementRow = $c->select(
                'INSERT INTO consignor_settlement
                   (consignor_party_id, period_start, period_end, gross_sales, commission_total,
                    net_payable, currency, status)
                 VALUES (:party, :start, :end, :gross, :commission, :net, :currency, \'finalized\')
                 RETURNING id',
                [
                    'party' => $consignorPartyId,
                    'start' => $periodStart,
                    'end' => $periodEnd,
                    'gross' => $gross->amount(),
                    'commission' => $commission->amount(),
                    'net' => $net->amount(),
                    'currency' => $currency,
                ],
            )->first();

            if ($settlementRow === null) {
                throw new RuntimeException('Failed to create the consignor settlement.');
            }

            $settlementId = Value::str($settlementRow->get('id'));

            foreach ($lines as $line) {
                $c->execute(
                    'INSERT INTO settlement_line
                       (settlement_id, sale_line_id, gross_amount, commission_amount, net_amount)
                     VALUES (:settlement, :sale_line, :gross, :commission, :net)',
                    [
                        'settlement' => $settlementId,
                        'sale_line' => $line['sale_line_id'],
                        'gross' => $line['gross'],
                        'commission' => $line['commission'],
                        'net' => $line['net'],
                    ],
                );
            }

            if (!$net->isPositive()) {
                throw new InvalidArgumentException('Settlement net payable is not positive; nothing to pay.');
            }

            $payoutRow = $c->select(
                'INSERT INTO consignor_payout (settlement_id, payout_amount, currency, payout_date, method)
                 VALUES (:settlement, :amount, :currency, :date, :method)
                 RETURNING id',
                [
                    'settlement' => $settlementId,
                    'amount' => $net->amount(),
                    'currency' => $currency,
                    'date' => $payoutDate,
                    'method' => $method,
                ],
            )->first();

            if ($payoutRow === null) {
                throw new RuntimeException('Failed to create the consignor payout.');
            }

            $payoutId = Value::str($payoutRow->get('id'));
            $key = $idempotencyKey ?? 'consignor_payout:' . $payoutId;

            $entryId = $c->scalarString('SELECT post_consignor_payout(:payout, :date, :key)', [
                'payout' => $payoutId,
                'date' => $payoutDate,
                'key' => $key,
            ]);

            return [
                'settlementId' => $settlementId,
                'payoutId' => $payoutId,
                'journalEntryId' => Value::str($entryId),
                'netPayable' => $net->amount(),
            ];
        });
    }
}
