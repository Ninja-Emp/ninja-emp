<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

use PDO;
use PDOException;

final class LedgerPoster
{
    public function __construct(
        private readonly PDO $pdo,
    ) {
    }

    public function post(Posting $posting): PostedJournal
    {
        if (!$this->pdo->inTransaction()) {
            throw new LedgerError('JOURNAL_FAILED', 'A journal posts inside a transaction');
        }
        $book = $this->primaryBook($posting->currency());
        $existing = $this->findByPostingKey($book['book_id'], $posting->postingKey());
        if ($existing !== null) {
            return $existing;
        }
        $prepared = $this->prepare($posting);
        $periodId = $this->periodId($book['book_id'], $posting->postingDate(), $posting->reversal());
        $journalNo = $this->nextJournalNo($book['book_id']);
        $prevHash = $this->lockPrevHash($book['book_id']);
        $occurredAt = $this->occurredAt($posting->occurredAt());
        $payload = JournalHash::payloadV2(
            $posting->postingKey(),
            $posting->postingDate(),
            $occurredAt,
            $periodId,
            $journalNo,
            $posting->currency(),
            $posting->sourceType(),
            $posting->sourceReference(),
            $posting->description(),
            $posting->reversal(),
            $posting->reversesJournalId(),
            $prepared['hashLines'],
        );
        try {
            $this->pdo->exec('SET CONSTRAINTS journals_balanced DEFERRED');
            $journalId = $this->insertJournal(
                $book['book_id'],
                $journalNo,
                $posting,
                $periodId,
                $occurredAt,
                $prepared['debit'],
                $prepared['credit'],
                $prevHash,
                JournalHash::hash($prevHash, $payload),
            );
            $this->insertLines($journalId, $prepared['rows']);
            $this->pdo->exec('SET CONSTRAINTS ALL IMMEDIATE');
        } catch (PDOException $error) {
            $raced = $this->recoverRace($book['book_id'], $posting->postingKey(), $error);
            if ($raced !== null) {
                return $raced;
            }
            throw $error;
        }
        return new PostedJournal($journalId, $journalNo, $posting->postingKey(), false);
    }

    /**
     * @return array{book_id: string, currency: string}
     */
    private function primaryBook(string $currency): array
    {
        $row = $this->pdo->query("SELECT book_id::text AS book_id, currency FROM ledger_books WHERE code = 'PRIMARY'")->fetch();
        if ($row === false) {
            throw new LedgerError('BOOK_MISSING', 'Primary book is not seeded');
        }
        $bookCurrency = rtrim((string) $row['currency']);
        if ($bookCurrency !== $currency) {
            throw new LedgerError('CURRENCY_MISMATCH', 'Journal currency must match the store money');
        }
        return ['book_id' => (string) $row['book_id'], 'currency' => $bookCurrency];
    }

    private function findByPostingKey(string $bookId, string $postingKey): ?PostedJournal
    {
        $select = $this->pdo->prepare(
            'SELECT journal_id::text AS journal_id, journal_no::text AS journal_no, posting_key FROM journals WHERE book_id = ? AND posting_key = ?',
        );
        $select->execute([$bookId, $postingKey]);
        $row = $select->fetch();
        if ($row === false) {
            return null;
        }
        return new PostedJournal((string) $row['journal_id'], (string) $row['journal_no'], (string) $row['posting_key'], true);
    }

    /**
     * @return array{debit: int, credit: int, hashLines: list<array{accountCode: string, debitMinor: string, creditMinor: string, subledgerType: string|null, subledgerRef: string|null}>, rows: list<array{accountId: string, debit: int, credit: int, subledgerType: string|null, subledgerRef: string|null, memo: string|null}>}
     */
    private function prepare(Posting $posting): array
    {
        if ($posting->postingKey() === '' || strlen($posting->postingKey()) > 190) {
            throw new LedgerError('JOURNAL_INVALID', 'Posting key is required');
        }
        if ($posting->description() === '') {
            throw new LedgerError('JOURNAL_INVALID', 'A journal needs a description');
        }
        if (!preg_match('/^\d{4}-\d{2}-\d{2}$/', $posting->postingDate())) {
            throw new LedgerError('JOURNAL_INVALID', 'Posting date must be an ISO date');
        }
        if (count($posting->lines()) < 2) {
            throw new LedgerError('JOURNAL_UNBALANCED', 'A journal needs at least two lines');
        }
        if ($posting->reversal() && ($posting->reversesJournalId() === null || $posting->reversesJournalId() === '')) {
            throw new LedgerError('JOURNAL_INVALID', 'A reversal must name the journal it reverses');
        }
        $debit = 0;
        $credit = 0;
        $hashLines = [];
        $rows = [];
        foreach ($posting->lines() as $line) {
            if ($line->debit()->currency() !== $posting->currency() || $line->credit()->currency() !== $posting->currency()) {
                throw new LedgerError('CURRENCY_MISMATCH', 'Every journal line must use the store money');
            }
            if ($line->debit()->isZero() === $line->credit()->isZero()) {
                throw new LedgerError('JOURNAL_LINE_INVALID', 'Each line is a debit or a credit, not both');
            }
            $account = $this->account($line->accountCode());
            $subledgerType = $line->subledgerType();
            $subledgerRef = $line->subledgerRef();
            if ($account['control'] && $account['subledger'] === 'party') {
                if ($subledgerType !== 'party' || $subledgerRef === null || $subledgerRef === '') {
                    throw new LedgerError('JOURNAL_LINE_INVALID', 'Rent, payable, and clawback lines need a vendor');
                }
            }
            $debit += $line->debit()->minor();
            $credit += $line->credit()->minor();
            $hashLines[] = [
                'accountCode' => $line->accountCode(),
                'debitMinor' => $line->debit()->minorString(),
                'creditMinor' => $line->credit()->minorString(),
                'subledgerType' => $subledgerType,
                'subledgerRef' => $subledgerRef,
            ];
            $rows[] = [
                'accountId' => $account['id'],
                'debit' => $line->debit()->minor(),
                'credit' => $line->credit()->minor(),
                'subledgerType' => $subledgerType,
                'subledgerRef' => $subledgerRef,
                'memo' => $line->memo(),
            ];
        }
        if ($debit !== $credit) {
            throw new LedgerError('JOURNAL_UNBALANCED', 'Debits must equal credits');
        }
        return ['debit' => $debit, 'credit' => $credit, 'hashLines' => $hashLines, 'rows' => $rows];
    }

    /**
     * @return array{id: string, control: bool, subledger: string}
     */
    private function account(string $code): array
    {
        $select = $this->pdo->prepare(
            'SELECT account_id::text AS account_id, is_postable, is_control, subledger_type FROM accounts WHERE code = ?',
        );
        $select->execute([$code]);
        $row = $select->fetch();
        if ($row === false) {
            throw new LedgerError('ACCOUNT_MISSING', 'Account ' . $code . ' is not on the chart');
        }
        if (!$this->pgBool($row['is_postable'])) {
            throw new LedgerError('ACCOUNT_NOT_POSTABLE', 'Account ' . $code . ' cannot be posted');
        }
        return [
            'id' => (string) $row['account_id'],
            'control' => $this->pgBool($row['is_control']),
            'subledger' => (string) ($row['subledger_type'] ?? ''),
        ];
    }

    private function periodId(string $bookId, string $postingDate, bool $reversal): string
    {
        $start = substr($postingDate, 0, 8) . '01';
        $end = substr($postingDate, 0, 8) . sprintf('%02d', (int) date('t', strtotime($postingDate . ' UTC')));
        $select = $this->pdo->prepare(
            'SELECT period_id::text AS period_id, status FROM accounting_periods WHERE book_id = ? AND starts_on = ? AND ends_on = ?',
        );
        $select->execute([$bookId, $start, $end]);
        $row = $select->fetch();
        if ($row === false) {
            $insert = $this->pdo->prepare(
                "INSERT INTO accounting_periods (book_id, starts_on, ends_on, status) VALUES (?, ?, ?, 'open') RETURNING period_id::text AS period_id",
            );
            $insert->execute([$bookId, $start, $end]);
            $created = $insert->fetch();
            if ($created === false) {
                throw new LedgerError('PERIOD_FAILED', 'Could not open the month');
            }
            return (string) $created['period_id'];
        }
        $status = (string) $row['status'];
        if ($status === 'hard_closed') {
            throw new LedgerError('PERIOD_CLOSED', 'That month is closed');
        }
        if ($status === 'soft_closed' && !$reversal) {
            throw new LedgerError('PERIOD_REVIEW', 'That month is being reviewed');
        }
        return (string) $row['period_id'];
    }

    private function nextJournalNo(string $bookId): string
    {
        $insert = $this->pdo->prepare(
            "INSERT INTO accounting_sequences (book_id, scope, next_value) VALUES (?, 'journal', 1) ON CONFLICT (book_id, scope) DO NOTHING",
        );
        $insert->execute([$bookId]);
        $update = $this->pdo->prepare(
            "UPDATE accounting_sequences SET next_value = next_value + 1 WHERE book_id = ? AND scope = 'journal' RETURNING (next_value - 1)::text AS consumed",
        );
        $update->execute([$bookId]);
        $row = $update->fetch();
        if ($row === false || preg_match('/^[1-9][0-9]*$/', (string) $row['consumed']) !== 1) {
            throw new LedgerError('JOURNAL_FAILED', 'Journal sequence did not advance');
        }
        return (string) $row['consumed'];
    }

    private function lockPrevHash(string $bookId): ?string
    {
        $select = $this->pdo->prepare(
            'SELECT entry_hash FROM journals WHERE book_id = ? ORDER BY journal_no DESC LIMIT 1 FOR UPDATE',
        );
        $select->execute([$bookId]);
        $hash = $select->fetchColumn();
        if ($hash === false) {
            return null;
        }
        return rtrim((string) $hash);
    }

    private function occurredAt(string $occurredAt): string
    {
        $parsed = \DateTimeImmutable::createFromFormat('Y-m-d\TH:i:s.v\Z', $occurredAt, new \DateTimeZone('UTC'));
        if ($parsed === false || $parsed->format('Y-m-d\TH:i:s.v\Z') !== $occurredAt) {
            throw new LedgerError('JOURNAL_INVALID', 'Occurred time must be UTC with milliseconds');
        }
        return $occurredAt;
    }

    private function insertJournal(
        string $bookId,
        string $journalNo,
        Posting $posting,
        string $periodId,
        string $occurredAt,
        int $debit,
        int $credit,
        ?string $prevHash,
        string $entryHash,
    ): string {
        $insert = $this->pdo->prepare(
            'INSERT INTO journals (book_id, journal_no, posting_key, posting_date, occurred_at, period_id, currency, source_type, source_reference, description, is_reversal, reverses_journal_id, total_debits_minor, total_credits_minor, prev_hash, entry_hash, hash_scheme) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING journal_id::text AS journal_id',
        );
        $insert->execute([
            $bookId,
            $journalNo,
            $posting->postingKey(),
            $posting->postingDate(),
            $occurredAt,
            $periodId,
            $posting->currency(),
            $posting->sourceType(),
            $posting->sourceReference(),
            $posting->description(),
            $posting->reversal() ? 'true' : 'false',
            $posting->reversesJournalId(),
            $debit,
            $credit,
            $prevHash,
            $entryHash,
            JournalHash::SCHEME_V2,
        ]);
        $row = $insert->fetch();
        if ($row === false) {
            throw new LedgerError('JOURNAL_FAILED', 'Journal insert returned no row');
        }
        return (string) $row['journal_id'];
    }

    /**
     * @param list<array{accountId: string, debit: int, credit: int, subledgerType: string|null, subledgerRef: string|null, memo: string|null}> $rows
     */
    private function insertLines(string $journalId, array $rows): void
    {
        $insert = $this->pdo->prepare(
            'INSERT INTO journal_lines (journal_id, line_no, account_id, debit_minor, credit_minor, subledger_type, subledger_ref, memo) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
        );
        $lineNo = 1;
        foreach ($rows as $row) {
            $insert->execute([
                $journalId,
                $lineNo,
                $row['accountId'],
                $row['debit'],
                $row['credit'],
                $row['subledgerType'],
                $row['subledgerRef'],
                $row['memo'],
            ]);
            $lineNo++;
        }
    }

    private function recoverRace(string $bookId, string $postingKey, PDOException $error): ?PostedJournal
    {
        if ((string) $error->getCode() !== '23505' || !str_contains($error->getMessage(), 'journals_posting_key_key')) {
            return null;
        }
        return $this->findByPostingKey($bookId, $postingKey);
    }

    private function pgBool(mixed $value): bool
    {
        if (is_bool($value)) {
            return $value;
        }
        return $value === 't' || $value === '1' || $value === 1;
    }
}
