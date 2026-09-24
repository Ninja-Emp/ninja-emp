<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Shared\Ledger\JournalLine;
use EmpPos\Shared\Ledger\LedgerError;
use EmpPos\Shared\Ledger\LedgerPoster;
use EmpPos\Shared\Ledger\Money;
use EmpPos\Shared\Ledger\Posting;
use EmpPos\Shared\Ledger\TrialBalance;
use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\DemoSeeder;

$pdo = Database::connectFromEnv();
$database = $pdo->query('SELECT current_database()')->fetchColumn();
if ($database !== 'emp_pos') {
    fwrite(STDERR, "Ledger proof refuses to write outside emp_pos\n");
    exit(1);
}
$pdo->exec('SET search_path TO "' . DemoSeeder::SCHEMA . '", public');
$poster = new LedgerPoster($pdo);
$trial = new TrialBalance($pdo);
$party = '018f0000-0000-7000-8000-000000000020';

$pdo->beginTransaction();
try {
    $trial->assertBalanced();
    $first = $poster->post(new Posting(
        'je:proof:poster',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Proof poster',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    ));
    if ($first->reused() || $first->journalNo() !== '11') {
        throw new RuntimeException('First post did not take journal 11');
    }
    $again = $poster->post(new Posting(
        'je:proof:poster',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Proof poster',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    ));
    if (!$again->reused() || $again->journalId() !== $first->journalId()) {
        throw new RuntimeException('The same posting key appended a second journal');
    }
    expectCode($poster, 'JOURNAL_UNBALANCED', static fn (): mixed => $poster->post(new Posting(
        'je:proof:one-line',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'One line',
        [new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD'))],
    )));
    expectCode($poster, 'JOURNAL_UNBALANCED', static fn (): mixed => $poster->post(new Posting(
        'je:proof:unbalanced',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Unbalanced',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(50, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:payable',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Payable without a vendor',
        [
            new JournalLine('2000', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
    expectCode($poster, 'ACCOUNT_MISSING', static fn (): mixed => $poster->post(new Posting(
        'je:proof:missing',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Missing account',
        [
            new JournalLine('9999', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
    expectCode($poster, 'CURRENCY_MISMATCH', static fn (): mixed => $poster->post(new Posting(
        'je:proof:cad',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'CAD',
        'owner_capital',
        'Wrong currency',
        [
            new JournalLine('1010', Money::of(100, 'CAD'), Money::zero('CAD')),
            new JournalLine('3000', Money::zero('CAD'), Money::of(100, 'CAD')),
        ],
    )));
    $posted = $poster->post(new Posting(
        'je:proof:party',
        '2026-09-12',
        '2026-09-12T18:01:00.000Z',
        'USD',
        'payable_rent_settlement',
        'Named apply',
        [
            new JournalLine('2000', Money::of(100, 'USD'), Money::zero('USD'), 'party', $party),
            new JournalLine('1300', Money::zero('USD'), Money::of(100, 'USD'), 'party', $party),
        ],
    ));
    if ($posted->reused() || $posted->journalNo() !== '12') {
        throw new RuntimeException('Party lines did not post');
    }
    $trial->assertBalanced();
    $pdo->rollBack();
} catch (Throwable $error) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }
    throw $error;
}

$pdo->beginTransaction();
try {
    $update = $pdo->prepare("UPDATE accounting_periods SET status = 'hard_closed' WHERE starts_on = '2026-09-01'");
    $update->execute();
    expectCode($poster, 'PERIOD_CLOSED', static fn (): mixed => $poster->post(new Posting(
        'je:proof:closed',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Closed month',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
    $pdo->rollBack();
} catch (Throwable $error) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }
    throw $error;
}

$pdo->beginTransaction();
try {
    $book = $pdo->query("SELECT book_id::text AS book_id FROM ledger_books WHERE code = 'PRIMARY'")->fetch();
    $period = $pdo->query("SELECT period_id::text AS period_id FROM accounting_periods WHERE starts_on = '2026-09-01'")->fetch();
    $tip = $pdo->query('SELECT entry_hash FROM journals ORDER BY journal_no DESC LIMIT 1')->fetchColumn();
    $insert = $pdo->prepare(
        'INSERT INTO journals (book_id, journal_no, posting_key, posting_date, occurred_at, period_id, currency, source_type, description, is_reversal, total_debits_minor, total_credits_minor, prev_hash, entry_hash, hash_scheme) VALUES (?, 901, \'je:proof:drift\', \'2026-09-12\', \'2026-09-12T18:00:00.000Z\', ?, \'USD\', \'owner_capital\', \'Drift\', false, 100, 100, ?, ?, 2) RETURNING journal_id::text AS journal_id',
    );
    $insert->execute([$book['book_id'], $period['period_id'], rtrim((string) $tip), str_repeat('a', 64)]);
    $journalId = (string) $insert->fetch()['journal_id'];
    $line = $pdo->prepare(
        'INSERT INTO journal_lines (journal_id, line_no, account_id, debit_minor, credit_minor) SELECT ?, ?, account_id, ?, ? FROM accounts WHERE code = ?',
    );
    $line->execute([$journalId, 1, 100, 0, '1010']);
    $line->execute([$journalId, 2, 0, 50, '3000']);
    $drifted = false;
    try {
        $trial->assertBalanced();
    } catch (LedgerError $error) {
        $drifted = $error->errorCode() === 'TRIAL_BALANCE_DRIFT';
    }
    if (!$drifted) {
        throw new RuntimeException('A drifted trial balance was allowed');
    }
    $pdo->rollBack();
} catch (Throwable $error) {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }
    throw $error;
}

$count = $pdo->query('SELECT COUNT(*) FROM journals')->fetchColumn();
if ((string) $count !== '10') {
    fwrite(STDERR, "Demo journals changed\n");
    exit(1);
}
fwrite(STDOUT, "ledger holds\n");

function expectCode(LedgerPoster $poster, string $code, callable $action): void
{
    try {
        $action();
    } catch (LedgerError $error) {
        if ($error->errorCode() === $code) {
            return;
        }
        throw $error;
    }
    throw new RuntimeException($code . ' was allowed');
}
