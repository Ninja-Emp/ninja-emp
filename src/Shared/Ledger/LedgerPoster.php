<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

use EmpPos\Shared\Scalar;
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
        $occurredAt = $this->occurredAt($posting->occurredAt());
        $periodId = $this->periodId($book['book_id'], $posting->postingDate(), $posting->reversal());
        $journalNo = $this->nextJournalNo($book['book_id']);
        $prevHash = $this->lockPrevHash($book['book_id']);
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
        $statement = $this->pdo->query("SELECT book_id::text AS book_id, currency FROM ledger_books WHERE code = 'PRIMARY'");
        if ($statement === false) {
            throw new LedgerError('JOURNAL_FAILED', 'Primary book query failed');
        }
        $fetched = $statement->fetch();
        if ($fetched === false) {
            throw new LedgerError('BOOK_MISSING', 'Primary book is not seeded');
        }
        $row = Scalar::row($fetched);
        $bookCurrency = rtrim(Scalar::text($row, 'currency'));
        if ($bookCurrency !== $currency) {
            throw new LedgerError('CURRENCY_MISMATCH', 'Journal currency must match the store money');
        }
        return ['book_id' => Scalar::text($row, 'book_id'), 'currency' => $bookCurrency];
    }

    private function findByPostingKey(string $bookId, string $postingKey): ?PostedJournal
    {
        $select = $this->pdo->prepare(
            'SELECT journal_id::text AS journal_id, journal_no::text AS journal_no, posting_key FROM journals WHERE book_id = ? AND posting_key = ?',
        );
        $select->execute([$bookId, $postingKey]);
        $fetched = $select->fetch();
        if ($fetched === false) {
            return null;
        }
        $row = Scalar::row($fetched);
        return new PostedJournal(Scalar::text($row, 'journal_id'), Scalar::text($row, 'journal_no'), Scalar::text($row, 'posting_key'), true);
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
        JournalRules::assert($posting);
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
        $this->assertPayable($posting);
        return ['debit' => $debit, 'credit' => $credit, 'hashLines' => $hashLines, 'rows' => $rows];
    }

    private function assertPayable(Posting $posting): void
    {
        /** @var array<string, int> $deltaByParty */
        $deltaByParty = [];
        $accountDelta = 0;
        $sawAccount = false;
        foreach ($posting->lines() as $line) {
            if ($line->accountCode() !== '2000') {
                continue;
            }
            $delta = $line->credit()->minor() - $line->debit()->minor();
            $accountDelta += $delta;
            $sawAccount = true;
            $party = $line->subledgerRef();
            if ($party === null || $party === '') {
                continue;
            }
            $deltaByParty[$party] = ($deltaByParty[$party] ?? 0) + $delta;
        }
        if (!$sawAccount) {
            return;
        }
        foreach ($deltaByParty as $party => $delta) {
            $this->assertPayableBalance($delta, $party);
        }
        if ($deltaByParty === []) {
            $this->assertPayableBalance($accountDelta, null);
        }
    }

    private function assertPayableBalance(int $delta, ?string $party): void
    {
        if ($party === null) {
            $select = $this->pdo->prepare(
                "SELECT (COALESCE(SUM(l.credit_minor - l.debit_minor), 0) + ?::bigint)::text AS owed
                 FROM journal_lines l
                 JOIN accounts a ON a.account_id = l.account_id
                 WHERE a.code = '2000'",
            );
            $select->execute([$delta]);
        } else {
            $select = $this->pdo->prepare(
                "SELECT (COALESCE(SUM(l.credit_minor - l.debit_minor), 0) + ?::bigint)::text AS owed
                 FROM journal_lines l
                 JOIN accounts a ON a.account_id = l.account_id
                 WHERE a.code = '2000' AND l.subledger_ref = ?",
            );
            $select->execute([$delta, $party]);
        }
        $owed = $select->fetchColumn();
        if ($owed === false || str_starts_with((string) $owed, '-')) {
            throw new LedgerError('PAYABLE_NEGATIVE', 'Payable cannot go negative');
        }
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
        $fetched = $select->fetch();
        if ($fetched === false) {
            throw new LedgerError('ACCOUNT_MISSING', 'Account ' . $code . ' is not on the chart');
        }
        $row = Scalar::row($fetched);
        if (!$this->pgBool($row['is_postable'])) {
            throw new LedgerError('ACCOUNT_NOT_POSTABLE', 'Account ' . $code . ' cannot be posted');
        }
        return [
            'id' => Scalar::text($row, 'account_id'),
            'control' => $this->pgBool($row['is_control']),
            'subledger' => Scalar::nullableText($row, 'subledger_type') ?? '',
        ];
    }

    private function periodId(string $bookId, string $postingDate, bool $reversal): string
    {
        $start = substr($postingDate, 0, 8) . '01';
        $timestamp = strtotime($postingDate . ' UTC');
        if ($timestamp === false) {
            throw new LedgerError('JOURNAL_INVALID', 'Posting date must be an ISO date');
        }
        $end = substr($postingDate, 0, 8) . sprintf('%02d', (int) date('t', $timestamp));
        $select = $this->pdo->prepare(
            'SELECT period_id::text AS period_id, status FROM accounting_periods WHERE book_id = ? AND starts_on = ? AND ends_on = ?',
        );
        $select->execute([$bookId, $start, $end]);
        $fetched = $select->fetch();
        if ($fetched === false) {
            $insert = $this->pdo->prepare(
                "INSERT INTO accounting_periods (book_id, starts_on, ends_on, status) VALUES (?, ?, ?, 'open') RETURNING period_id::text AS period_id",
            );
            $insert->execute([$bookId, $start, $end]);
            $created = $insert->fetch();
            if ($created === false) {
                throw new LedgerError('PERIOD_FAILED', 'Could not open the month');
            }
            return Scalar::text(Scalar::row($created), 'period_id');
        }
        $row = Scalar::row($fetched);
        $status = Scalar::text($row, 'status');
        if ($status === 'hard_closed') {
            throw new LedgerError('PERIOD_CLOSED', 'That month is closed');
        }
        if ($status === 'soft_closed' && !$reversal) {
            throw new LedgerError('PERIOD_REVIEW', 'That month is being reviewed');
        }
        return Scalar::text($row, 'period_id');
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
        $fetched = $update->fetch();
        if ($fetched === false) {
            throw new LedgerError('JOURNAL_FAILED', 'Journal sequence did not advance');
        }
        $consumed = Scalar::text(Scalar::row($fetched), 'consumed');
        if (preg_match('/^[1-9][0-9]*$/', $consumed) !== 1) {
            throw new LedgerError('JOURNAL_FAILED', 'Journal sequence did not advance');
        }
        return $consumed;
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
        $fetched = $insert->fetch();
        if ($fetched === false) {
            throw new LedgerError('JOURNAL_FAILED', 'Journal insert returned no row');
        }
        return Scalar::text(Scalar::row($fetched), 'journal_id');
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
