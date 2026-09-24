<?php

declare(strict_types=1);

namespace EmpPos\Tests\Ledger;

use EmpPos\Shared\Ledger\JournalHash;
use EmpPos\Shared\Ledger\JournalLine;
use EmpPos\Shared\Ledger\JournalRules;
use EmpPos\Shared\Ledger\LedgerError;
use EmpPos\Shared\Ledger\Money;
use EmpPos\Shared\Ledger\Posting;
use PHPUnit\Framework\TestCase;

final class JournalRulesTest extends TestCase
{
    public function testRentReceiptCannotTouchPayable(): void
    {
        $this->expectException(LedgerError::class);
        JournalRules::assert($this->posting('rent_receipt', [
            $this->line('1000', '100', '0'),
            $this->line('1300', '0', '50', 'party', '018f0000-0000-7000-8000-000000000020'),
            $this->line('2000', '0', '50', 'party', '018f0000-0000-7000-8000-000000000020'),
        ]));
    }

    public function testOnlyNamedApplyMovesPayableToRent(): void
    {
        $this->expectException(LedgerError::class);
        JournalRules::assert($this->posting('owner_capital', [
            $this->line('2000', '50', '0', 'party', '018f0000-0000-7000-8000-000000000020'),
            $this->line('1300', '0', '50', 'party', '018f0000-0000-7000-8000-000000000020'),
        ]));
    }

    public function testNamedApplyRejectsAThirdAccount(): void
    {
        $this->expectException(LedgerError::class);
        JournalRules::assert($this->posting('payable_rent_settlement', [
            $this->line('2000', '50', '0', 'party', '018f0000-0000-7000-8000-000000000020'),
            $this->line('1300', '0', '40', 'party', '018f0000-0000-7000-8000-000000000020'),
            $this->line('1000', '0', '10'),
        ]));
    }

    public function testNamedApplyHolds(): void
    {
        JournalRules::assert($this->posting('payable_rent_settlement', [
            $this->line('2000', '50', '0', 'party', '018f0000-0000-7000-8000-000000000020'),
            $this->line('1300', '0', '50', 'party', '018f0000-0000-7000-8000-000000000020'),
        ]));
        self::assertSame(2, JournalHash::SCHEME_V2);
    }

    public function testFeeCannotTouchPayableOrTax(): void
    {
        foreach (['rent_late_fee', 'processor_fee', 'cash_rounding', 'register_over_short'] as $source) {
            try {
                JournalRules::assert($this->posting($source, [
                    $this->line('6170', '10', '0'),
                    $this->line('2000', '0', '10', 'party', '018f0000-0000-7000-8000-000000000020'),
                ]));
                self::fail($source);
            } catch (LedgerError $error) {
                self::assertSame('JOURNAL_LINE_INVALID', $error->errorCode());
            }
            try {
                JournalRules::assert($this->posting($source, [
                    $this->line('6170', '10', '0'),
                    $this->line('2100', '0', '10'),
                ]));
                self::fail($source . ' tax');
            } catch (LedgerError $error) {
                self::assertSame('JOURNAL_LINE_INVALID', $error->errorCode());
            }
        }
    }

    public function testRelabelingAFeeStillCannotTouchPayable(): void
    {
        try {
            JournalRules::assert($this->posting('owner_capital', [
                $this->line('6170', '10', '0'),
                $this->line('2000', '0', '10', 'party', '018f0000-0000-7000-8000-000000000020'),
            ]));
            self::fail('relabel');
        } catch (LedgerError $error) {
            self::assertSame('JOURNAL_LINE_INVALID', $error->errorCode());
        }
        JournalRules::assert($this->posting('sale', [
            $this->line('1000', '110', '0'),
            $this->line('2000', '0', '100', 'party', '018f0000-0000-7000-8000-000000000020'),
            $this->line('6150', '0', '10'),
        ]));
    }

    public function testHashIsStable(): void
    {
        $lines = [[
            'accountCode' => '1010',
            'debitMinor' => '100',
            'creditMinor' => '0',
            'subledgerType' => null,
            'subledgerRef' => null,
        ]];
        $payload = JournalHash::payloadV2('k', '2026-09-12', '2026-09-12T18:00:00.000Z', 'p', '1', 'USD', 'owner_capital', null, 'Open', false, null, $lines);
        $hash = JournalHash::hash(null, $payload);
        self::assertSame(64, strlen($hash));
        self::assertNotSame($hash, JournalHash::hash('prev', $payload));
    }

    /**
     * @param list<JournalLine> $lines
     */
    private function posting(string $source, array $lines): Posting
    {
        return new Posting('k', '2026-09-12', '2026-09-12T18:00:00.000Z', 'USD', $source, 'Proof', $lines);
    }

    private function line(string $code, string $debit, string $credit, ?string $type = null, ?string $ref = null): JournalLine
    {
        return new JournalLine($code, Money::fromMinorString($debit, 'USD'), Money::fromMinorString($credit, 'USD'), $type, $ref);
    }
}
