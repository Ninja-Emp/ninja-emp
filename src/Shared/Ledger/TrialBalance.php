<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

use EmpPos\Shared\Scalar;
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
     * @return array{currency: string, rows: list<array{code: string, name: string, debitMinor: string, creditMinor: string}>, totalDebitMinor: string, totalCreditMinor: string}
     */
    public function report(): array
    {
        $lines = $this->statement(
            "SELECT a.code, a.name, COALESCE(SUM(l.debit_minor), 0)::text AS debit, COALESCE(SUM(l.credit_minor), 0)::text AS credit
             FROM accounts a
             LEFT JOIN journal_lines l ON l.account_id = a.account_id
             GROUP BY a.code, a.name
             ORDER BY a.code",
        );
        $totals = $this->statement(
            'SELECT COALESCE(SUM(debit_minor), 0)::text AS debit, COALESCE(SUM(credit_minor), 0)::text AS credit FROM journal_lines',
        )->fetch();
        $book = $this->statement("SELECT currency FROM ledger_books WHERE code = 'PRIMARY'")->fetch();
        if ($totals === false || $book === false) {
            throw new LedgerError('TRIAL_BALANCE_DRIFT', 'The books are out of balance');
        }
        $totalRow = Scalar::row($totals);
        $bookRow = Scalar::row($book);
        $debit = Scalar::text($totalRow, 'debit');
        $credit = Scalar::text($totalRow, 'credit');
        if ($debit !== $credit) {
            throw new LedgerError('TRIAL_BALANCE_DRIFT', 'The books are out of balance');
        }
        $out = [];
        foreach ($lines->fetchAll() as $row) {
            $item = Scalar::row($row);
            $out[] = [
                'code' => Scalar::text($item, 'code'),
                'name' => Scalar::text($item, 'name'),
                'debitMinor' => Scalar::text($item, 'debit'),
                'creditMinor' => Scalar::text($item, 'credit'),
            ];
        }
        return [
            'currency' => rtrim(Scalar::text($bookRow, 'currency')),
            'rows' => $out,
            'totalDebitMinor' => $debit,
            'totalCreditMinor' => $credit,
        ];
    }

    private function statement(string $sql): \PDOStatement
    {
        $statement = $this->pdo->query($sql);
        if ($statement === false) {
            throw new LedgerError('TRIAL_BALANCE_DRIFT', 'The books are out of balance');
        }
        return $statement;
    }
}
