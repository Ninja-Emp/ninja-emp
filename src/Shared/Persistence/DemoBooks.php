<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use EmpPos\Shared\Ledger\JournalHash;
use EmpPos\Shared\Scalar;
use PDO;
use RuntimeException;

final class DemoBooks
{
    public function assertSaturday(PDO $pdo): void
    {
        $this->assertBalanced($pdo);
        $this->assertHashes($pdo);
        $this->assertNets($pdo);
        $this->assertPayableNeverNegative($pdo);
        $this->assertRentDoesNotTouchPayable($pdo);
        $this->assertOnlyNamedApply($pdo);
    }

    private function assertBalanced(PDO $pdo): void
    {
        $statement = Sql::statement(
            $pdo,
            'SELECT COALESCE(SUM(debit_minor), 0) AS debit, COALESCE(SUM(credit_minor), 0) AS credit FROM journal_lines',
        );
        $fetched = $statement->fetch();
        if ($fetched === false) {
            throw new RuntimeException('Demo journals are not balanced');
        }
        $row = Scalar::row($fetched);
        if (Scalar::text($row, 'debit') !== Scalar::text($row, 'credit')) {
            throw new RuntimeException('Demo journals are not balanced');
        }
    }

    private function assertHashes(PDO $pdo): void
    {
        $journals = Sql::rows(
            $pdo,
            "SELECT journal_id::text AS journal_id, journal_no::text AS journal_no, posting_key, posting_date::text AS posting_date,
                    to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS occurred_at,
                    period_id::text AS period_id, currency, source_type, source_reference, description,
                    is_reversal, reverses_journal_id::text AS reverses_journal_id, prev_hash, entry_hash, hash_scheme
             FROM journals
             ORDER BY journals.journal_no",
        );
        if ($journals === []) {
            throw new RuntimeException('Demo store has no journals');
        }
        $prev = null;
        foreach ($journals as $journal) {
            if (Scalar::int($journal, 'hash_scheme') !== JournalHash::SCHEME_V2) {
                throw new RuntimeException('Demo journal ' . Scalar::text($journal, 'journal_no') . ' is not hash scheme v2');
            }
            $lines = $this->lines($pdo, Scalar::text($journal, 'journal_id'));
            $payload = JournalHash::payloadV2(
                Scalar::text($journal, 'posting_key'),
                Scalar::text($journal, 'posting_date'),
                Scalar::text($journal, 'occurred_at'),
                Scalar::text($journal, 'period_id'),
                Scalar::text($journal, 'journal_no'),
                rtrim(Scalar::text($journal, 'currency')),
                Scalar::text($journal, 'source_type'),
                Scalar::nullableText($journal, 'source_reference'),
                Scalar::text($journal, 'description'),
                $this->pgBool($journal['is_reversal']),
                Scalar::nullableText($journal, 'reverses_journal_id'),
                $lines,
            );
            $hash = JournalHash::hash($prev, $payload);
            if (!hash_equals($hash, rtrim(Scalar::text($journal, 'entry_hash')))) {
                throw new RuntimeException('Demo journal ' . Scalar::text($journal, 'journal_no') . ' hash does not match its lines');
            }
            $prevHash = Scalar::nullableText($journal, 'prev_hash');
            if ($prev !== null && $prevHash !== $prev) {
                throw new RuntimeException('Demo journal ' . Scalar::text($journal, 'journal_no') . ' broke the hash chain');
            }
            $prev = $hash;
        }
    }

    /**
     * @return list<array{accountCode: string, debitMinor: string, creditMinor: string, subledgerType: string|null, subledgerRef: string|null}>
     */
    private function lines(PDO $pdo, string $journalId): array
    {
        $select = $pdo->prepare(
            'SELECT a.code AS account_code, l.debit_minor::text AS debit_minor, l.credit_minor::text AS credit_minor,
                    l.subledger_type, l.subledger_ref::text AS subledger_ref
             FROM journal_lines l
             JOIN accounts a ON a.account_id = l.account_id
             WHERE l.journal_id = ?
             ORDER BY l.line_no',
        );
        $select->execute([$journalId]);
        $lines = [];
        foreach ($select->fetchAll() as $line) {
            $row = Scalar::row($line);
            $lines[] = [
                'accountCode' => Scalar::text($row, 'account_code'),
                'debitMinor' => Scalar::text($row, 'debit_minor'),
                'creditMinor' => Scalar::text($row, 'credit_minor'),
                'subledgerType' => Scalar::nullableText($row, 'subledger_type'),
                'subledgerRef' => Scalar::nullableText($row, 'subledger_ref'),
            ];
        }
        return $lines;
    }

    private function pgBool(mixed $value): bool
    {
        if (is_bool($value)) {
            return $value;
        }
        return $value === 't' || $value === '1' || $value === 1;
    }

    private function assertNets(PDO $pdo): void
    {
        $expected = [
            '1000' => '12000',
            '1010' => '48800',
            '1300' => '1000',
            '1310' => '200',
            '2000' => '0',
            '3000' => '-50000',
            '4000' => '-4000',
            '4100' => '-8000',
        ];
        $rows = Sql::rows(
            $pdo,
            'SELECT a.code, COALESCE(SUM(l.debit_minor - l.credit_minor), 0)::text AS net
             FROM accounts a
             LEFT JOIN journal_lines l ON l.account_id = a.account_id
             WHERE a.code IN (\'1000\', \'1010\', \'1300\', \'1310\', \'2000\', \'3000\', \'4000\', \'4100\')
             GROUP BY a.code
             ORDER BY a.code',
        );
        $found = [];
        foreach ($rows as $row) {
            $found[Scalar::text($row, 'code')] = Scalar::text($row, 'net');
        }
        $matched = 0;
        foreach ($expected as $code => $net) {
            foreach ($found as $actualCode => $actualNet) {
                if ((string) $actualCode === (string) $code && $actualNet === $net) {
                    $matched++;
                }
            }
        }
        if ($matched !== count($expected)) {
            throw new RuntimeException('Demo account nets do not match');
        }
    }

    private function assertPayableNeverNegative(PDO $pdo): void
    {
        $rows = Sql::rows(
            $pdo,
            "SELECT j.journal_no, COALESCE(SUM(l.credit_minor - l.debit_minor), 0)::text AS delta
             FROM journals j
             JOIN journal_lines l ON l.journal_id = j.journal_id
             JOIN accounts a ON a.account_id = l.account_id
             WHERE a.code = '2000'
             GROUP BY j.journal_no
             ORDER BY j.journal_no",
        );
        $balance = 0;
        foreach ($rows as $row) {
            $balance += Scalar::int($row, 'delta');
            if ($balance < 0) {
                throw new RuntimeException('Demo payable went negative at journal ' . Scalar::text($row, 'journal_no'));
            }
        }
    }

    private function assertRentDoesNotTouchPayable(PDO $pdo): void
    {
        $count = Sql::column(
            $pdo,
            "SELECT COUNT(*) FROM journal_lines l
             JOIN journals j ON j.journal_id = l.journal_id
             JOIN accounts a ON a.account_id = l.account_id
             WHERE j.source_type = 'rent_receipt' AND a.code = '2000'",
        );
        if (Scalar::string($count, 'count') !== '0') {
            throw new RuntimeException('A rent receipt debited payable');
        }
    }

    private function assertOnlyNamedApply(PDO $pdo): void
    {
        $rows = Sql::rows(
            $pdo,
            "SELECT j.source_type
             FROM journals j
             WHERE EXISTS (
                 SELECT 1 FROM journal_lines l
                 JOIN accounts a ON a.account_id = l.account_id
                 WHERE l.journal_id = j.journal_id AND a.code = '2000'
             )
             AND EXISTS (
                 SELECT 1 FROM journal_lines l
                 JOIN accounts a ON a.account_id = l.account_id
                 WHERE l.journal_id = j.journal_id AND a.code = '1300'
             )
             ORDER BY j.journal_no",
        );
        if (count($rows) !== 1 || Scalar::text($rows[0], 'source_type') !== 'payable_rent_settlement') {
            throw new RuntimeException('Payable moved to rent outside the named apply');
        }
    }
}
