<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

final class JournalRules
{
    private const array RENT_RECEIPT_DEBITS = ['1000', '1100', '1200'];

    private const array FEE_ACCOUNTS = ['4200', '6170', '6180'];

    private const string TILL_ACCOUNT = '6150';

    private const array TAX_ACCOUNTS = ['2100'];

    private const array SALE_SOURCES = ['sale', 'sale_return'];

    public static function assert(Posting $posting): void
    {
        $codes = [];
        $debits = [];
        $credits = [];
        foreach ($posting->lines() as $line) {
            $code = $line->accountCode();
            $codes[] = $code;
            if (!$line->debit()->isZero()) {
                $debits[] = $code;
            }
            if (!$line->credit()->isZero()) {
                $credits[] = $code;
            }
        }
        self::assertRentReceipt($debits, $credits, $codes);
        self::assertApply($posting->sourceType(), $debits, $credits, $codes);
        self::assertFee($posting->sourceType(), $codes);
        self::assertHaircut($debits, $credits, $codes);
    }

    /**
     * @param list<string> $debits
     * @param list<string> $credits
     * @param list<string> $codes
     */
    private static function assertRentReceipt(array $debits, array $credits, array $codes): void
    {
        if (!in_array('1300', $credits, true)) {
            return;
        }
        $receiptDebit = false;
        foreach (self::RENT_RECEIPT_DEBITS as $code) {
            if (in_array($code, $debits, true)) {
                $receiptDebit = true;
            }
        }
        if ($receiptDebit && in_array('2000', $codes, true)) {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'A rent receipt never touches payable');
        }
    }

    /**
     * @param list<string> $debits
     * @param list<string> $credits
     * @param list<string> $codes
     */
    private static function assertApply(string $sourceType, array $debits, array $credits, array $codes): void
    {
        $movesPayableToRent = in_array('2000', $debits, true) && in_array('1300', $credits, true);
        $namedApply = $sourceType === 'payable_rent_settlement';
        if (!$movesPayableToRent && !$namedApply) {
            return;
        }
        if (!$namedApply || !$movesPayableToRent) {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'Only the named apply moves payable to rent');
        }
        foreach ($codes as $code) {
            if ($code !== '2000' && $code !== '1300') {
                throw new LedgerError('JOURNAL_LINE_INVALID', 'The named apply only uses payable and rent receivable');
            }
        }
    }

    /**
     * @param list<string> $codes
     */
    private static function assertFee(string $sourceType, array $codes): void
    {
        if (in_array($sourceType, ['rent_late_fee', 'processor_fee', 'cash_rounding', 'register_over_short'], true)) {
            self::rejectPayableOrTax($codes);
        }
        foreach (self::FEE_ACCOUNTS as $fee) {
            if (in_array($fee, $codes, true)) {
                self::rejectPayableOrTax($codes);
            }
        }
        if (in_array(self::TILL_ACCOUNT, $codes, true) && !in_array($sourceType, self::SALE_SOURCES, true)) {
            self::rejectPayableOrTax($codes);
        }
    }

    /**
     * @param list<string> $debits
     * @param list<string> $credits
     * @param list<string> $codes
     */
    private static function assertHaircut(array $debits, array $credits, array $codes): void
    {
        if (in_array('4100', $credits, true) && !in_array('1300', $debits, true)) {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'Rent income stays on rent receivable');
        }
        foreach (['4100', '5100', '6160'] as $blocked) {
            if (in_array($blocked, $codes, true) && in_array('2000', $codes, true)) {
                throw new LedgerError('JOURNAL_LINE_INVALID', 'Payable is not income');
            }
        }
        if (!in_array('2000', $debits, true)) {
            return;
        }
        foreach (['4000', '4300'] as $income) {
            if (in_array($income, $credits, true)) {
                throw new LedgerError('JOURNAL_LINE_INVALID', 'Payable is not income');
            }
        }
    }

    /**
     * The raw journal route is not a second register. Sale, rent, payout, and till post through their own commands.
     */
    public static function assertManual(Posting $posting): void
    {
        if ($posting->sourceType() !== 'owner_capital') {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'This route only posts owner capital');
        }
        foreach ($posting->lines() as $line) {
            if ($line->accountCode() !== '1010' && $line->accountCode() !== '3000') {
                throw new LedgerError('JOURNAL_LINE_INVALID', 'This route only posts owner capital');
            }
        }
    }

    /**
     * @param list<string> $codes
     */
    private static function rejectPayableOrTax(array $codes): void
    {
        if (in_array('2000', $codes, true)) {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'A fee, rounding, or till difference never touches payable');
        }
        foreach (self::TAX_ACCOUNTS as $tax) {
            if (in_array($tax, $codes, true)) {
                throw new LedgerError('JOURNAL_LINE_INVALID', 'A fee, rounding, or till difference never touches tax');
            }
        }
    }
}
