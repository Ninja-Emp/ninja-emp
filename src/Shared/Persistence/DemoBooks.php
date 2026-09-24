<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use EmpPos\Shared\Ledger\JournalHash;
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
        $row = $pdo->query(
            'SELECT COALESCE(SUM(debit_minor), 0) AS debit, COALESCE(SUM(credit_minor), 0) AS credit FROM journal_lines',
        )->fetch();
        if ($row === false || (string) $row['debit'] !== (string) $row['credit']) {
            throw new RuntimeException('Demo journals are not balanced');
        }
    }

    private function assertHashes(PDO $pdo): void
    {
        $journals = $pdo->query(
            "SELECT journal_id::text AS journal_id, journal_no::text AS journal_no, posting_key, posting_date::text AS posting_date,
                    to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS occurred_at,
                    period_id::text AS period_id, currency, source_type, source_reference, description,
                    is_reversal, reverses_journal_id::text AS reverses_journal_id, prev_hash, entry_hash, hash_scheme
             FROM journals
             ORDER BY journals.journal_no",
        )->fetchAll();
        if ($journals === []) {
            throw new RuntimeException('Demo store has no journals');
        }
        $prev = null;
        foreach ($journals as $journal) {
            if ((int) $journal['hash_scheme'] !== JournalHash::SCHEME_V2) {
                throw new RuntimeException('Demo journal ' . $journal['journal_no'] . ' is not hash scheme v2');
            }
            $lines = $this->lines($pdo, (string) $journal['journal_id']);
            $payload = JournalHash::payloadV2(
                (string) $journal['posting_key'],
                (string) $journal['posting_date'],
                (string) $journal['occurred_at'],
                (string) $journal['period_id'],
                (string) $journal['journal_no'],
                (string) $journal['currency'],
                (string) $journal['source_type'],
                $journal['source_reference'] !== null ? (string) $journal['source_reference'] : null,
                (string) $journal['description'],
                $this->pgBool($journal['is_reversal']),
                $journal['reverses_journal_id'] !== null ? (string) $journal['reverses_journal_id'] : null,
                $lines,
            );
            $hash = JournalHash::hash($prev, $payload);
            if (!hash_equals($hash, (string) $journal['entry_hash'])) {
                throw new RuntimeException('Demo journal ' . $journal['journal_no'] . ' hash does not match its lines');
            }
            if ($prev !== null && (string) $journal['prev_hash'] !== $prev) {
                throw new RuntimeException('Demo journal ' . $journal['journal_no'] . ' broke the hash chain');
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
            $lines[] = [
                'accountCode' => (string) $line['account_code'],
                'debitMinor' => (string) $line['debit_minor'],
                'creditMinor' => (string) $line['credit_minor'],
                'subledgerType' => $line['subledger_type'] !== null ? (string) $line['subledger_type'] : null,
                'subledgerRef' => $line['subledger_ref'] !== null ? (string) $line['subledger_ref'] : null,
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
        $rows = $pdo->query(
            'SELECT a.code, COALESCE(SUM(l.debit_minor - l.credit_minor), 0)::text AS net
             FROM accounts a
             LEFT JOIN journal_lines l ON l.account_id = a.account_id
             WHERE a.code IN (\'1000\', \'1010\', \'1300\', \'1310\', \'2000\', \'3000\', \'4000\', \'4100\')
             GROUP BY a.code
             ORDER BY a.code',
        )->fetchAll();
        $found = [];
        foreach ($rows as $row) {
            $found[(string) $row['code']] = (string) $row['net'];
        }
        foreach ($expected as $code => $net) {
            if (($found[$code] ?? null) !== $net) {
                throw new RuntimeException('Demo account ' . $code . ' net is not ' . $net);
            }
        }
    }

    private function assertPayableNeverNegative(PDO $pdo): void
    {
        $rows = $pdo->query(
            "SELECT j.journal_no, COALESCE(SUM(l.credit_minor - l.debit_minor), 0)::text AS delta
             FROM journals j
             JOIN journal_lines l ON l.journal_id = j.journal_id
             JOIN accounts a ON a.account_id = l.account_id
             WHERE a.code = '2000'
             GROUP BY j.journal_no
             ORDER BY j.journal_no",
        )->fetchAll();
        $balance = 0;
        foreach ($rows as $row) {
            $balance += (int) $row['delta'];
            if ($balance < 0) {
                throw new RuntimeException('Demo payable went negative at journal ' . $row['journal_no']);
            }
        }
    }

    private function assertRentDoesNotTouchPayable(PDO $pdo): void
    {
        $count = $pdo->query(
            "SELECT COUNT(*) FROM journal_lines l
             JOIN journals j ON j.journal_id = l.journal_id
             JOIN accounts a ON a.account_id = l.account_id
             WHERE j.source_type = 'rent_receipt' AND a.code = '2000'",
        )->fetchColumn();
        if ((string) $count !== '0') {
            throw new RuntimeException('A rent receipt debited payable');
        }
    }

    private function assertOnlyNamedApply(PDO $pdo): void
    {
        $rows = $pdo->query(
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
        )->fetchAll();
        if (count($rows) !== 1 || (string) $rows[0]['source_type'] !== 'payable_rent_settlement') {
            throw new RuntimeException('Payable moved to rent outside the named apply');
        }
    }
}
