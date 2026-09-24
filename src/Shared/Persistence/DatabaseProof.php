<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use PDO;
use PDOException;
use RuntimeException;

final class DatabaseProof
{
    private const string BOOK = '018f0000-0000-7000-8000-000000000010';

    private const string PERIOD = '018f0000-0000-7000-8000-000000000011';

    private const string PARTY = '018f0000-0000-7000-8000-000000000020';

    private const string BOOTH = '018f0000-0000-7000-8000-000000000021';

    private const string REGISTER = '018f0000-0000-7000-8000-000000000030';

    private const string SESSION = '018f0000-0000-7000-8000-000000000031';

    private const string MEMBERSHIP = '018f0000-0000-7000-8000-000000000004';

    private const string OPENING = '018f0000-0000-7000-8000-000000000101';

    private const string BOWL_SALE = '018f0000-0000-7000-8000-000000000203';

    public function __construct(
        private PDO $pdo,
        private DemoSeeder $seeder,
    ) {
    }

    /**
     * @return list<string>
     */
    public function prove(): array
    {
        $database = $this->pdo->query('SELECT current_database()')->fetchColumn();
        if ($database !== 'emp_pos') {
            throw new RuntimeException('Database proof refuses to write outside emp_pos');
        }
        $this->pdo->exec('SET search_path TO "' . DemoSeeder::SCHEMA . '", public');
        $this->requireDemo();

        $proved = [
            $this->expect('23505', 'journals_genesis_key', 'second opening journal', function (): void {
                $this->insertJournal(901, 'je:proof:genesis', null, $this->hash('a'), 100, 100);
            }),
            $this->expect('23505', 'journals_posting_key_key', 'duplicate posting key', function (): void {
                $this->insertJournal(902, 'je:owner-capital:opening', $this->tipHash(), $this->hash('b'), 100, 100);
            }),
            $this->expect('23514', 'journal is not balanced', 'unbalanced journal lines', function (): void {
                $journal = $this->proofId(903);
                $this->insertJournal(903, 'je:proof:unbalanced', $this->tipHash(), $this->hash('c'), 100, 100);
                $this->insertLine($journal, 1, '1000', 100, 0);
                $this->insertLine($journal, 2, '3000', 0, 50);
            }),
            $this->expect('23514', 'journal must have at least two lines', 'one-line journal', function (): void {
                $journal = $this->proofId(904);
                $this->insertJournal(904, 'je:proof:one-line', $this->tipHash(), $this->hash('d'), 100, 100);
                $this->insertLine($journal, 1, '1000', 100, 0);
            }),
            $this->expect('25006', 'ledger rows are append-only', 'journal update', function (): void {
                $this->pdo->exec('UPDATE journals SET description = description WHERE journal_no = 1');
            }),
            $this->expect('25006', 'ledger rows are append-only', 'journal line delete', function (): void {
                $delete = $this->pdo->prepare('DELETE FROM journal_lines WHERE journal_id = ?');
                $delete->execute([self::OPENING]);
            }),
            $this->expect('25006', 'audit events are append-only', 'audit update', function (): void {
                $this->pdo->exec("UPDATE audit_events SET message = message WHERE action = 'register_open'");
            }),
            $this->expect('25006', 'cash drops are append-only', 'cash drop update', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO register_cash_drops (cash_drop_id, register_session_id, amount_minor, currency, dropped_by_membership_id) VALUES (?, ?, 100, \'USD\', ?)',
                );
                $insert->execute([$this->proofId(905), self::SESSION, self::MEMBERSHIP]);
                $update = $this->pdo->prepare('UPDATE register_cash_drops SET amount_minor = 50 WHERE cash_drop_id = ?');
                $update->execute([$this->proofId(905)]);
            }),
            $this->expect('23505', 'booths_code_lower_key', 'duplicate booth code', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO booths (booth_id, booth_code, size, default_rent_minor, default_rent_currency) VALUES (?, \' a12 \', \'10x10\', 8000, \'USD\')',
                );
                $insert->execute([$this->proofId(906)]);
            }),
            $this->expect('23P01', 'booth assignment overlaps', 'overlapping booth assignment', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO booth_assignments (assignment_id, booth_id, party_id, starts_on, rent_amount_minor, currency) VALUES (?, ?, ?, \'2026-09-15\', 8000, \'USD\')',
                );
                $insert->execute([$this->proofId(907), self::BOOTH, self::PARTY]);
            }),
            $this->expect('23P01', 'accounting period overlaps', 'overlapping period', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO accounting_periods (period_id, book_id, starts_on, ends_on, status) VALUES (?, ?, \'2026-09-15\', \'2026-10-15\', \'open\')',
                );
                $insert->execute([$this->proofId(908), self::BOOK]);
            }),
            $this->expect('23514', 'sale journal does not match the sale', 'sale on the wrong journal', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO sales (sale_id, register_id, sold_on, sold_at, currency, status, journal_id, tax_exempt, ticket_discount_minor, ticket_discount_bps, house_buy, change_minor, cash_rounding_adjustment_minor, checkout_kind) VALUES (?, ?, \'2026-09-12\', \'2026-09-12T18:00:00Z\', \'USD\', \'completed\', ?, false, 0, 0, false, 0, 0, \'central\')',
                );
                $insert->execute([$this->proofId(909), self::REGISTER, self::OPENING]);
            }),
            $this->expect('23514', 'return journal does not match the return', 'return on the wrong journal', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO sale_returns (sale_return_id, sale_id, returned_on, amount_minor, currency, journal_id, cash_amount_minor, card_amount_minor, check_amount_minor, gift_amount_minor, vendor_purchase_amount_minor, store_credit_amount_minor, cash_rounding_adjustment_minor) VALUES (?, ?, \'2026-09-12\', 1000, \'USD\', ?, 1000, 0, 0, 0, 0, 0, 0)',
                );
                $insert->execute([$this->proofId(910), self::BOWL_SALE, self::OPENING]);
            }),
            $this->expect('23514', 'rent receipt journal does not match the receipt', 'rent receipt on the wrong journal', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO rent_receipts (rent_receipt_id, party_id, received_on, amount_minor, currency, journal_id, method, status) VALUES (?, ?, \'2026-09-12\', 1, \'USD\', ?, \'cash\', \'completed\')',
                );
                $insert->execute([$this->proofId(911), self::PARTY, self::OPENING]);
            }),
            $this->expect('23514', 'payout journal does not match the payout', 'payout on the wrong journal', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO holder_payouts (holder_payout_id, party_id, paid_on, amount_minor, currency, journal_id, method, check_number, status) VALUES (?, ?, \'2026-09-12\', 1, \'USD\', ?, \'check\', \'9099\', \'completed\')',
                );
                $insert->execute([$this->proofId(912), self::PARTY, self::OPENING]);
            }),
            $this->expect('23505', 'holder_payouts_check_number_key', 'duplicate check number', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO holder_payouts (holder_payout_id, party_id, paid_on, amount_minor, currency, journal_id, method, check_number, status) VALUES (?, ?, \'2026-09-12\', 50000, \'USD\', ?, \'check\', \'1001\', \'completed\')',
                );
                $insert->execute([$this->proofId(913), self::PARTY, self::OPENING]);
            }),
            $this->expect('23514', 'holder_payouts_cash_register_chk', 'ACH payout', function (): void {
                $insert = $this->pdo->prepare(
                    'INSERT INTO holder_payouts (holder_payout_id, party_id, paid_on, amount_minor, currency, journal_id, method, status) VALUES (?, ?, \'2026-09-12\', 1, \'USD\', ?, \'ach\', \'completed\')',
                );
                $insert->execute([$this->proofId(914), self::PARTY, self::OPENING]);
            }),
        ];

        $this->seeder->assertLiveWipeRefused();
        $proved[] = 'live store wipe';
        $this->requireDemo();
        return $proved;
    }

    private function requireDemo(): void
    {
        $status = $this->pdo->prepare('SELECT status FROM public.tenants WHERE slug = ?');
        $status->execute([DemoSeeder::SLUG]);
        if ($status->fetchColumn() !== 'demo') {
            throw new RuntimeException('Demo store is not in demo status');
        }
        $journals = $this->pdo->query('SELECT COUNT(*) FROM journals')->fetchColumn();
        if ((string) $journals !== '10') {
            throw new RuntimeException('Demo store does not have its ten journals');
        }
    }

    private function expect(string $state, string $fragment, string $name, callable $action): string
    {
        $this->pdo->beginTransaction();
        try {
            $action();
            $this->pdo->exec('SET CONSTRAINTS ALL IMMEDIATE');
            $this->pdo->rollBack();
            throw new RuntimeException($name . ' was allowed');
        } catch (PDOException $error) {
            if ($this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }
            $code = (string) $error->getCode();
            if ($code !== $state || !str_contains($error->getMessage(), $fragment)) {
                throw new RuntimeException($name . ' raised ' . $code . ' ' . $error->getMessage(), 0, $error);
            }
        }
        return $name;
    }

    private function insertJournal(int $number, string $postingKey, ?string $prevHash, string $entryHash, int $debit, int $credit): void
    {
        $insert = $this->pdo->prepare(
            'INSERT INTO journals (journal_id, book_id, journal_no, posting_key, posting_date, occurred_at, period_id, currency, source_type, description, is_reversal, total_debits_minor, total_credits_minor, prev_hash, entry_hash, hash_scheme) VALUES (?, ?, ?, ?, \'2026-09-12\', \'2026-09-12T18:00:00Z\', ?, \'USD\', \'owner_capital\', \'Proof\', false, ?, ?, ?, ?, 2)',
        );
        $insert->execute([
            $this->proofId($number),
            self::BOOK,
            $number,
            $postingKey,
            self::PERIOD,
            $debit,
            $credit,
            $prevHash,
            $entryHash,
        ]);
    }

    private function insertLine(string $journalId, int $lineNo, string $code, int $debit, int $credit): void
    {
        $insert = $this->pdo->prepare(
            'INSERT INTO journal_lines (journal_id, line_no, account_id, debit_minor, credit_minor) SELECT ?, ?, account_id, ?, ? FROM accounts WHERE code = ?',
        );
        $insert->execute([$journalId, $lineNo, $debit, $credit, $code]);
    }

    private function tipHash(): string
    {
        $hash = $this->pdo->query('SELECT entry_hash FROM journals WHERE journal_no = 10')->fetchColumn();
        if (!is_string($hash) || strlen(rtrim($hash)) !== 64) {
            throw new RuntimeException('Demo chain has no tip hash');
        }
        return rtrim($hash);
    }

    private function proofId(int $number): string
    {
        return sprintf('018f0000-0000-7000-8000-%012d', $number);
    }

    private function hash(string $mark): string
    {
        return str_repeat($mark, 64);
    }
}
