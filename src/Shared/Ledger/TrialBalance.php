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
        $row = $this->pdo->query(
            'SELECT COALESCE(SUM(debit_minor), 0)::text AS debit, COALESCE(SUM(credit_minor), 0)::text AS credit FROM journal_lines',
        )->fetch();
        if ($row === false || (string) $row['debit'] !== (string) $row['credit']) {
            throw new LedgerError('TRIAL_BALANCE_DRIFT', 'The books are out of balance');
        }
    }
}
