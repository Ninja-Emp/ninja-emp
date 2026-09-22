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
 * The point-of-sale domain service.
 *
 * It owns the *document* side of a sale — building the sale, its lines, the
 * payment and its tenders — and then hands the ledger side to the database's own
 * posting functions (post_sale, post_sale_inventory). The application layer never
 * re-implements posting: the DB functions are the single source of truth for the
 * ledger (ADR-0020/0028/0029/0031).
 *
 * Everything runs in one transaction, so the deferred invariants (sale totals =
 * Σ lines, tenders = payment amount, the ledger balance trigger) all fire at
 * COMMIT and a half-written sale can never be observed.
 *
 * Money is a 4-dp decimal string end to end. The commission split is exact by
 * construction: net_to_consignor is the remainder after the commission, so
 * commission + net always equals the extended price to the last unit.
 */
final class PosService
{
    public function __construct(private readonly Connection $conn)
    {
    }

    /**
     * Ring up and post a sale. Idempotent when the request carries an
     * idempotency key (or one can be derived from its content).
     *
     * @SuppressWarnings("CyclomaticComplexity") the branch count is the sale
     *   pipeline (validate → price → commission → tax → post → persist).
     */
    public function ringUp(SaleRequest $request): SaleResult
    {
        $currency = $request->currency;
        $entryDate = $request->saleDate ?? date('Y-m-d');
        $key = $request->idempotencyKey ?? $this->deriveKey($request, $entryDate);

        return $this->conn->transactional(function (Connection $c) use ($request, $currency, $entryDate, $key): SaleResult {
            // --- Compute the document totals exactly -------------------------
            $subtotal = Money::zero(Currency::of($currency));
            $discountTotal = Money::zero(Currency::of($currency));
            $taxTotal = Money::zero(Currency::of($currency));

            /** @var list<array{line:SaleLineInput, extended:Money, commission:Money, net:Money}> $prepared */
            $prepared = [];

            foreach ($request->lines as $line) {
                $qty = $line->quantity;
                $unit = Money::of($line->unitPrice, Currency::of($currency));
                $discount = Money::of($line->discountAmount, Currency::of($currency));

                $gross = $unit->times($qty);
                $extended = $gross->minus($discount);

                if ($extended->isNegative()) {
                    throw new InvalidArgumentException('A line discount cannot exceed its extended price.');
                }

                $commission = Money::zero(Currency::of($currency));
                $net = Money::zero(Currency::of($currency));

                if ($line->isConsignment()) {
                    $commission = $extended->times(Value::str($line->commissionRate));
                    $net = $extended->minus($commission); // exact remainder
                }

                $tax = Money::of($line->taxAmount, Currency::of($currency));

                $subtotal = $subtotal->plus($gross);
                $discountTotal = $discountTotal->plus($discount);
                $taxTotal = $taxTotal->plus($tax);

                $prepared[] = ['line' => $line, 'extended' => $extended, 'commission' => $commission, 'net' => $net];
            }

            $total = $subtotal->minus($discountTotal)->plus($taxTotal);

            // --- Tenders must cover the total exactly ------------------------
            $tenderSum = Money::zero(Currency::of($currency));

            foreach ($request->tenders as $tender) {
                $tenderSum = $tenderSum->plus(Money::of($tender->amount, Currency::of($currency)));
            }

            if (!$tenderSum->equals($total)) {
                throw new InvalidArgumentException(\sprintf(
                    'Tenders (%s) do not equal the sale total (%s).',
                    $tenderSum->amount(),
                    $total->amount(),
                ));
            }

            // --- Persist the sale header -------------------------------------
            $saleRow = $c->select(
                'INSERT INTO sale
                   (register_id, shift_id, customer_party_id, sale_date, channel,
                    subtotal, discount_total, tax_total, total, currency, status)
                 VALUES
                   (:register, :shift, :customer, :date, :channel,
                    :subtotal, :discount, :tax, :total, :currency, \'completed\')
                 RETURNING id, sale_no',
                [
                    'register' => $request->registerId,
                    'shift' => $request->shiftId,
                    'customer' => $request->customerPartyId,
                    'date' => $entryDate,
                    'channel' => $request->channel,
                    'subtotal' => $subtotal->amount(),
                    'discount' => $discountTotal->amount(),
                    'tax' => $taxTotal->amount(),
                    'total' => $total->amount(),
                    'currency' => $currency,
                ],
            )->first();

            if ($saleRow === null) {
                throw new RuntimeException('Failed to insert the sale header.');
            }

            $saleId = Value::str($saleRow->get('id'));
            $saleNo = Value::str($saleRow->get('sale_no'));

            // --- Persist the lines -------------------------------------------
            $lineNo = 0;

            foreach ($prepared as $p) {
                $lineNo++;
                $line = $p['line'];

                $c->execute(
                    'INSERT INTO sale_line
                       (sale_id, line_no, line_kind, consignment_item_id, consignor_party_id,
                        vendor_party_id, sku, description, quantity, unit_price, discount_amount,
                        extended_price, commission_rate, commission_amount, net_to_consignor,
                        unit_cost, is_taxable, tax_amount, inventory_item_id, currency)
                     VALUES
                       (:sale, :line_no, :kind, :consignment_item, :consignor,
                        :vendor, :sku, :description, :quantity, :unit_price, :discount,
                        :extended, :commission_rate, :commission_amount, :net,
                        :unit_cost, :is_taxable, :tax_amount, :inventory_item, :currency)',
                    [
                        'sale' => $saleId,
                        'line_no' => $lineNo,
                        'kind' => $line->kind,
                        'consignment_item' => $line->consignmentItemId,
                        'consignor' => $line->consignorPartyId,
                        'vendor' => $line->vendorPartyId,
                        'sku' => $line->sku,
                        'description' => $line->description,
                        'quantity' => $line->quantity,
                        'unit_price' => $line->unitPrice,
                        'discount' => $line->discountAmount,
                        'extended' => $p['extended']->amount(),
                        'commission_rate' => $line->commissionRate,
                        'commission_amount' => $p['commission']->amount(),
                        'net' => $p['net']->amount(),
                        'unit_cost' => $line->unitCost,
                        'is_taxable' => $line->isTaxable ? 'true' : 'false',
                        'tax_amount' => $line->taxAmount,
                        'inventory_item' => $line->inventoryItemId,
                        'currency' => $currency,
                    ],
                );
            }

            // --- Persist the payment and its tenders -------------------------
            $paymentRow = $c->select(
                'INSERT INTO payment (sale_id, payment_date, amount, currency, status)
                 VALUES (:sale, :date, :amount, :currency, \'captured\')
                 RETURNING id',
                [
                    'sale' => $saleId,
                    'date' => $entryDate,
                    'amount' => $total->amount(),
                    'currency' => $currency,
                ],
            )->first();

            if ($paymentRow === null) {
                throw new RuntimeException('Failed to insert the payment.');
            }

            $paymentId = Value::str($paymentRow->get('id'));

            foreach ($request->tenders as $tender) {
                $c->execute(
                    'INSERT INTO payment_tender
                       (payment_id, tender_type_code, amount, currency, party_id, card_last4, processor_ref)
                     VALUES (:payment, :tender, :amount, :currency, :party, :last4, :ref)',
                    [
                        'payment' => $paymentId,
                        'tender' => $tender->code,
                        'amount' => $tender->amount,
                        'currency' => $currency,
                        'party' => $tender->partyId,
                        'last4' => $tender->cardLast4,
                        'ref' => $tender->processorRef,
                    ],
                );
            }

            // --- Hand the ledger side to the database ------------------------
            $entryId = $c->scalarString('SELECT post_sale(:sale, :date, :key)', [
                'sale' => $saleId,
                'date' => $entryDate,
                'key' => $key,
            ]);

            $relieved = $c->scalarInt('SELECT post_sale_inventory(:sale, :date)', [
                'sale' => $saleId,
                'date' => $entryDate,
            ]);

            return new SaleResult(
                saleId: $saleId,
                saleNo: $saleNo,
                subtotal: $subtotal->amount(),
                discountTotal: $discountTotal->amount(),
                taxTotal: $taxTotal->amount(),
                total: $total->amount(),
                currency: $currency,
                journalEntryId: Value::str($entryId),
                inventoryLinesRelieved: $relieved,
            );
        });
    }

    /**
     * Refund a completed sale. A refund is its OWN document that reverses the
     * original (reversal-not-edit): we never mutate the original's journal entry.
     *
     * @param list<SaleLineInput> $lines the lines being returned (mirror of the original)
     * @param list<TenderInput> $tenders how the money goes back out
     */
    public function refund(
        string $originalSaleId,
        array $lines,
        array $tenders,
        string $currency = 'USD',
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): SaleResult {
        $entryDate ??= date('Y-m-d');
        $key = $idempotencyKey ?? 'refund:' . $originalSaleId . ':' . $entryDate;

        return $this->conn->transactional(function (Connection $c) use ($originalSaleId, $lines, $tenders, $currency, $entryDate, $key): SaleResult {
            $ccy = Currency::of($currency);

            $subtotal = Money::zero($ccy);
            $discountTotal = Money::zero($ccy);
            $taxTotal = Money::zero($ccy);
            $prepared = [];

            foreach ($lines as $line) {
                $unit = Money::of($line->unitPrice, $ccy);
                $discount = Money::of($line->discountAmount, $ccy);
                $gross = $unit->times($line->quantity);
                $extended = $gross->minus($discount);

                $commission = Money::zero($ccy);
                $net = Money::zero($ccy);

                if ($line->isConsignment()) {
                    $commission = $extended->times(Value::str($line->commissionRate));
                    $net = $extended->minus($commission);
                }

                $tax = Money::of($line->taxAmount, $ccy);
                $subtotal = $subtotal->plus($gross);
                $discountTotal = $discountTotal->plus($discount);
                $taxTotal = $taxTotal->plus($tax);

                $prepared[] = ['line' => $line, 'extended' => $extended, 'commission' => $commission, 'net' => $net];
            }

            $total = $subtotal->minus($discountTotal)->plus($taxTotal);

            $saleRow = $c->select(
                'INSERT INTO sale
                   (customer_party_id, sale_date, channel, subtotal, discount_total, tax_total,
                    total, currency, status, refunds_sale_id, is_refund)
                 VALUES
                   (NULL, :date, \'in_store\', :subtotal, :discount, :tax, :total, :currency,
                    \'completed\', :original, true)
                 RETURNING id, sale_no',
                [
                    'date' => $entryDate,
                    'subtotal' => $subtotal->amount(),
                    'discount' => $discountTotal->amount(),
                    'tax' => $taxTotal->amount(),
                    'total' => $total->amount(),
                    'currency' => $currency,
                    'original' => $originalSaleId,
                ],
            )->first();

            if ($saleRow === null) {
                throw new RuntimeException('Failed to insert the refund document.');
            }

            $saleId = Value::str($saleRow->get('id'));
            $saleNo = Value::str($saleRow->get('sale_no'));

            $lineNo = 0;

            foreach ($prepared as $p) {
                $lineNo++;
                $line = $p['line'];
                $c->execute(
                    'INSERT INTO sale_line
                       (sale_id, line_no, line_kind, consignment_item_id, consignor_party_id,
                        vendor_party_id, sku, description, quantity, unit_price, discount_amount,
                        extended_price, commission_rate, commission_amount, net_to_consignor,
                        unit_cost, is_taxable, tax_amount, inventory_item_id, currency)
                     VALUES
                       (:sale, :line_no, :kind, :consignment_item, :consignor,
                        :vendor, :sku, :description, :quantity, :unit_price, :discount,
                        :extended, :commission_rate, :commission_amount, :net,
                        :unit_cost, :is_taxable, :tax_amount, :inventory_item, :currency)',
                    [
                        'sale' => $saleId,
                        'line_no' => $lineNo,
                        'kind' => $line->kind,
                        'consignment_item' => $line->consignmentItemId,
                        'consignor' => $line->consignorPartyId,
                        'vendor' => $line->vendorPartyId,
                        'sku' => $line->sku,
                        'description' => $line->description,
                        'quantity' => $line->quantity,
                        'unit_price' => $line->unitPrice,
                        'discount' => $line->discountAmount,
                        'extended' => $p['extended']->amount(),
                        'commission_rate' => $line->commissionRate,
                        'commission_amount' => $p['commission']->amount(),
                        'net' => $p['net']->amount(),
                        'unit_cost' => $line->unitCost,
                        'is_taxable' => $line->isTaxable ? 'true' : 'false',
                        'tax_amount' => $line->taxAmount,
                        'inventory_item' => $line->inventoryItemId,
                        'currency' => $currency,
                    ],
                );
            }

            $paymentRow = $c->select(
                'INSERT INTO payment (sale_id, payment_date, amount, currency, status)
                 VALUES (:sale, :date, :amount, :currency, \'captured\')
                 RETURNING id',
                ['sale' => $saleId, 'date' => $entryDate, 'amount' => $total->amount(), 'currency' => $currency],
            )->first();

            if ($paymentRow === null) {
                throw new RuntimeException('Failed to insert the refund payment.');
            }

            $paymentId = Value::str($paymentRow->get('id'));

            foreach ($tenders as $tender) {
                $c->execute(
                    'INSERT INTO payment_tender
                       (payment_id, tender_type_code, amount, currency, party_id, card_last4, processor_ref)
                     VALUES (:payment, :tender, :amount, :currency, :party, :last4, :ref)',
                    [
                        'payment' => $paymentId,
                        'tender' => $tender->code,
                        'amount' => $tender->amount,
                        'currency' => $currency,
                        'party' => $tender->partyId,
                        'last4' => $tender->cardLast4,
                        'ref' => $tender->processorRef,
                    ],
                );
            }

            $entryId = $c->scalarString('SELECT post_refund(:sale, :date, :key)', [
                'sale' => $saleId,
                'date' => $entryDate,
                'key' => $key,
            ]);

            $relieved = $c->scalarInt('SELECT post_refund_inventory(:sale, :date)', [
                'sale' => $saleId,
                'date' => $entryDate,
            ]);

            return new SaleResult(
                saleId: $saleId,
                saleNo: $saleNo,
                subtotal: $subtotal->amount(),
                discountTotal: $discountTotal->amount(),
                taxTotal: $taxTotal->amount(),
                total: $total->amount(),
                currency: $currency,
                journalEntryId: Value::str($entryId),
                inventoryLinesRelieved: $relieved,
            );
        });
    }

    /**
     * Open a drawer session for a register.
     *
     * @return string the shift id
     */
    public function openShift(string $registerId, string $openingFloat, ?string $openedByPartyId = null, string $currency = 'USD'): string
    {
        return $this->conn->transactional(function (Connection $c) use ($registerId, $openingFloat, $openedByPartyId, $currency): string {
            $row = $c->select(
                'INSERT INTO shift (register_id, opened_by_party_id, opening_float, currency)
                 VALUES (:register, :opened_by, :float, :currency)
                 RETURNING id',
                [
                    'register' => $registerId,
                    'opened_by' => $openedByPartyId,
                    'float' => $openingFloat,
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
     * Close a drawer session: count the cash and book any over/short (ADR-0029).
     * Returns the over/short journal entry id, or null when the drawer balanced.
     */
    public function closeShift(string $shiftId, string $countedCash, ?string $entryDate = null, ?string $idempotencyKey = null): ?string
    {
        $entryDate ??= date('Y-m-d');
        $key = $idempotencyKey ?? 'shift_close:' . $shiftId . ':' . $entryDate;

        return $this->conn->transactional(function (Connection $c) use ($shiftId, $countedCash, $entryDate, $key): ?string {
            $entryId = $c->scalar('SELECT post_shift_close(:shift, :counted, :date, :key)', [
                'shift' => $shiftId,
                'counted' => $countedCash,
                'date' => $entryDate,
                'key' => $key,
            ]);

            return Value::nullableStr($entryId);
        });
    }

    /**
     * Record a processor payout: card clearing -> bank, with the fee expensed.
     *
     * @return string the settlement journal entry id
     */
    public function settleMerchant(
        string $grossAmount,
        string $feeAmount,
        string $currency = 'USD',
        ?string $processorRef = null,
        ?string $entryDate = null,
        ?string $idempotencyKey = null,
    ): string {
        $entryDate ??= date('Y-m-d');
        $ccy = Currency::of($currency);
        $gross = Money::of($grossAmount, $ccy);
        $fee = Money::of($feeAmount, $ccy);
        $net = $gross->minus($fee);

        return $this->conn->transactional(function (Connection $c) use ($gross, $fee, $net, $currency, $processorRef, $entryDate, $idempotencyKey): string {
            $row = $c->select(
                'INSERT INTO merchant_settlement
                   (settlement_date, gross_amount, fee_amount, net_amount, currency, processor_ref)
                 VALUES (:date, :gross, :fee, :net, :currency, :ref)
                 RETURNING id',
                [
                    'date' => $entryDate,
                    'gross' => $gross->amount(),
                    'fee' => $fee->amount(),
                    'net' => $net->amount(),
                    'currency' => $currency,
                    'ref' => $processorRef,
                ],
            )->first();

            if ($row === null) {
                throw new RuntimeException('Failed to insert the merchant settlement.');
            }

            $settlementId = Value::str($row->get('id'));
            $key = $idempotencyKey ?? 'merchant_settlement:' . $settlementId;

            $entryId = $c->scalarString('SELECT post_merchant_settlement(:settlement, :date, :key)', [
                'settlement' => $settlementId,
                'date' => $entryDate,
                'key' => $key,
            ]);

            return Value::str($entryId);
        });
    }

    /**
     * Derive a stable idempotency key from the request content, so a retried
     * ring-up returns the same ledger entry instead of double-posting.
     */
    private function deriveKey(SaleRequest $request, string $entryDate): string
    {
        $parts = [$entryDate, $request->currency, $request->registerId ?? '', $request->shiftId ?? '', $request->customerPartyId ?? ''];

        foreach ($request->lines as $line) {
            $parts[] = implode('|', [
                $line->kind, $line->sku ?? '', $line->quantity, $line->unitPrice,
                $line->discountAmount, $line->commissionRate ?? '', $line->consignorPartyId ?? '',
                $line->inventoryItemId ?? '', $line->taxAmount,
            ]);
        }

        foreach ($request->tenders as $tender) {
            $parts[] = implode('|', [$tender->code, $tender->amount, $tender->partyId ?? '']);
        }

        return 'pos_sale:' . hash('sha256', implode("\n", $parts));
    }
}
