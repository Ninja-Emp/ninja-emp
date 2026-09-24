<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

use EmpPos\Shared\Scalar;
use PDO;

final class JournalGuard
{
    public function __construct(
        private readonly PDO $pdo,
    ) {
    }

    public function assertSamePosting(PostedJournal $existing, Posting $posting): void
    {
        $select = $this->pdo->prepare(
            'SELECT posting_date::text AS posting_date,
                    to_char(occurred_at AT TIME ZONE \'UTC\', \'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"\') AS occurred_at,
                    currency, source_type, source_reference, description, is_reversal, reverses_journal_id::text AS reverses_journal_id
             FROM journals WHERE journal_id = ?',
        );
        $select->execute([$existing->journalId()]);
        $fetched = $select->fetch();
        if ($fetched === false) {
            throw new LedgerError('JOURNAL_FAILED', 'Stored journal disappeared');
        }
        $row = Scalar::row($fetched);
        $reverses = Scalar::nullableText($row, 'reverses_journal_id');
        $named = $posting->reversesJournalId();
        $same = rtrim(Scalar::text($row, 'currency')) === $posting->currency()
            && Scalar::text($row, 'source_type') === $posting->sourceType()
            && Scalar::text($row, 'description') === $posting->description()
            && Scalar::text($row, 'posting_date') === $posting->postingDate()
            && Scalar::text($row, 'occurred_at') === $posting->occurredAt()
            && Scalar::nullableText($row, 'source_reference') === $posting->sourceReference()
            && $this->pgBool($row['is_reversal']) === $posting->reversal()
            && $reverses === (($named === null || $named === '') ? null : $named);
        if (!$same || !$this->sameLines($existing->journalId(), $posting)) {
            throw new LedgerError('JOURNAL_INVALID', 'Posting key already belongs to a different journal');
        }
    }

    public function assertReversal(Posting $posting): void
    {
        $reverses = $posting->reversesJournalId();
        $named = $reverses !== null && $reverses !== '';
        if (!$posting->reversal()) {
            if ($named) {
                throw new LedgerError('JOURNAL_INVALID', 'Only a reversal names another journal');
            }
            return;
        }
        if (!$named) {
            throw new LedgerError('JOURNAL_INVALID', 'A reversal must name the journal it reverses');
        }
        if (preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $reverses) !== 1) {
            throw new LedgerError('JOURNAL_INVALID', 'A reversal must name the journal it reverses');
        }
        $select = $this->pdo->prepare('SELECT source_type FROM journals WHERE journal_id = ?');
        $select->execute([$reverses]);
        $source = $select->fetchColumn();
        if ($source === false || (string) $source !== 'owner_capital') {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'A reversal swaps the named owner-capital journal');
        }
        $taken = $this->pdo->prepare('SELECT journal_id FROM journals WHERE reverses_journal_id = ?');
        $taken->execute([$reverses]);
        if ($taken->fetch() !== false) {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'That journal is already reversed');
        }
        $lines = $this->pdo->prepare(
            'SELECT a.code, l.debit_minor::text AS debit_minor, l.credit_minor::text AS credit_minor
             FROM journal_lines l JOIN accounts a ON a.account_id = l.account_id
             WHERE l.journal_id = ? ORDER BY l.line_no',
        );
        $lines->execute([$reverses]);
        $stored = $lines->fetchAll();
        $incoming = $posting->lines();
        if (count($stored) !== count($incoming)) {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'A reversal swaps the named journal');
        }
        $index = 0;
        foreach ($stored as $item) {
            $row = Scalar::row($item);
            $line = $incoming[$index];
            $index++;
            if (Scalar::text($row, 'code') !== $line->accountCode()
                || Scalar::text($row, 'debit_minor') !== $line->credit()->minorString()
                || Scalar::text($row, 'credit_minor') !== $line->debit()->minorString()) {
                throw new LedgerError('JOURNAL_LINE_INVALID', 'A reversal swaps the named journal');
            }
        }
    }

    public function assertBank(Posting $posting): void
    {
        $delta = 0;
        foreach ($posting->lines() as $line) {
            if ($line->accountCode() !== '1010') {
                continue;
            }
            $delta = self::addMinor($delta, $line->debit()->minor());
            $credit = $line->credit()->minor();
            if ($credit > 0 && $delta < PHP_INT_MIN + $credit) {
                throw new LedgerError('INVALID_MONEY', 'Journal total is too large');
            }
            $delta -= $credit;
        }
        if ($delta >= 0) {
            return;
        }
        $lock = $this->pdo->prepare("SELECT account_id FROM accounts WHERE code = '1010' FOR UPDATE");
        $lock->execute();
        if ($lock->fetch() === false) {
            throw new LedgerError('ACCOUNT_MISSING', 'Account 1010 is not on the chart');
        }
        $select = $this->pdo->prepare(
            "SELECT (COALESCE(SUM(l.debit_minor - l.credit_minor), 0) + ?::bigint)::text AS balance
             FROM journal_lines l JOIN accounts a ON a.account_id = l.account_id WHERE a.code = '1010'",
        );
        $select->execute([$delta]);
        $balance = $select->fetchColumn();
        if ($balance === false || str_starts_with((string) $balance, '-')) {
            throw new LedgerError('JOURNAL_LINE_INVALID', 'The bank cannot go negative');
        }
    }

    public static function addMinor(int $total, int $minor): int
    {
        if ($minor > 0 && $total > PHP_INT_MAX - $minor) {
            throw new LedgerError('INVALID_MONEY', 'Journal total is too large');
        }
        return $total + $minor;
    }

    private function sameLines(string $journalId, Posting $posting): bool
    {
        $select = $this->pdo->prepare(
            'SELECT a.code, l.debit_minor::text AS debit_minor, l.credit_minor::text AS credit_minor, l.memo,
                    l.subledger_type, l.subledger_ref::text AS subledger_ref
             FROM journal_lines l JOIN accounts a ON a.account_id = l.account_id
             WHERE l.journal_id = ? ORDER BY l.line_no',
        );
        $select->execute([$journalId]);
        $stored = $select->fetchAll();
        $lines = $posting->lines();
        if (count($stored) !== count($lines)) {
            return false;
        }
        $index = 0;
        foreach ($stored as $item) {
            $row = Scalar::row($item);
            $line = $lines[$index];
            $index++;
            if (Scalar::text($row, 'code') !== $line->accountCode()
                || Scalar::text($row, 'debit_minor') !== $line->debit()->minorString()
                || Scalar::text($row, 'credit_minor') !== $line->credit()->minorString()
                || Scalar::nullableText($row, 'memo') !== $line->memo()
                || Scalar::nullableText($row, 'subledger_type') !== $line->subledgerType()
                || Scalar::nullableText($row, 'subledger_ref') !== $line->subledgerRef()) {
                return false;
            }
        }
        return true;
    }

    private function pgBool(mixed $value): bool
    {
        if (is_bool($value)) {
            return $value;
        }
        return $value === 't' || $value === '1' || $value === 1;
    }
}
