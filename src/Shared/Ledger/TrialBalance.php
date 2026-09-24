<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

use PDO;

final class TrialBalance
{
    public function __construct(
        private readonly PDO $pdo,
    ) {
    }

    public function assertBalanced(): void
    {
        $this->report();
    }

    /**
     * @return array{currency: string, rows: list<array{code: string, debitMinor: string, creditMinor: string}>, totalDebitMinor: string, totalCreditMinor: string}
     */
    public function report(): array
    {
        $rows = $this->pdo->query(
            "SELECT a.code, a.name, COALESCE(SUM(l.debit_minor), 0)::text AS debit, COALESCE(SUM(l.credit_minor), 0)::text AS credit
             FROM accounts a
             LEFT JOIN journal_lines l ON l.account_id = a.account_id
             GROUP BY a.code, a.name
             ORDER BY a.code",
        )->fetchAll();
        $book = $this->pdo->query("SELECT currency FROM ledger_books WHERE code = 'PRIMARY'")->fetch();
        $debit = 0;
        $credit = 0;
        $out = [];
        foreach ($rows as $row) {
            $debit += (int) $row['debit'];
            $credit += (int) $row['credit'];
            $out[] = [
                'code' => (string) $row['code'],
                'name' => (string) $row['name'],
                'debitMinor' => (string) $row['debit'],
                'creditMinor' => (string) $row['credit'],
            ];
        }
        if ($debit !== $credit) {
            throw new LedgerError('TRIAL_BALANCE_DRIFT', 'The books are out of balance');
        }
        return [
            'currency' => rtrim((string) ($book['currency'] ?? '')),
            'rows' => $out,
            'totalDebitMinor' => (string) $debit,
            'totalCreditMinor' => (string) $credit,
        ];
    }
}
