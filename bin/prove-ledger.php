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

function proveLedger(): void
{
$pdo = Database::connectFromEnv();
$database = $pdo->query('SELECT current_database()')->fetchColumn();
if ($database !== 'emp_pos') {
    throw new RuntimeException('Ledger proof refuses to write outside emp_pos');
}
$pdo->exec('SET search_path TO "' . DemoSeeder::SCHEMA . '", public');
$journalsBefore = $pdo->query('SELECT COUNT(*) FROM journals')->fetchColumn();
$poster = new LedgerPoster($pdo);
$trial = new TrialBalance($pdo);
$party = '018f0000-0000-7000-8000-000000000020';

expectCode($poster, 'JOURNAL_FAILED', static fn (): mixed => $poster->post(new Posting(
    'je:proof:outside',
    '2026-09-12',
    '2026-09-12T18:00:00.000Z',
    'USD',
    'owner_capital',
    'Outside',
    [
        new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
        new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
    ],
)));

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
    expectCode($poster, 'JOURNAL_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:poster',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Different body',
        [
            new JournalLine('1010', Money::of(50, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(50, 'USD')),
        ],
    )));
    $reversed = $poster->post(new Posting(
        'je:proof:reverse',
        '2026-09-12',
        '2026-09-12T18:07:00.000Z',
        'USD',
        'owner_capital',
        'Reverse the proof journal',
        [
            new JournalLine('1010', Money::zero('USD'), Money::of(100, 'USD')),
            new JournalLine('3000', Money::of(100, 'USD'), Money::zero('USD')),
        ],
        null,
        true,
        $first->journalId(),
    ));
    if ($reversed->reused()) {
        throw new RuntimeException('Reversal was treated as a replay');
    }
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:reverse-again',
        '2026-09-12',
        '2026-09-12T18:08:00.000Z',
        'USD',
        'owner_capital',
        'Reverse twice',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
        null,
        true,
        $first->journalId(),
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:fake-reversal',
        '2026-09-12',
        '2026-09-12T18:09:00.000Z',
        'USD',
        'owner_capital',
        'Fake reversal',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
        null,
        true,
        '018f0000-0000-7000-8000-000000000099',
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:overdraw',
        '2026-09-12',
        '2026-09-12T18:10:00.000Z',
        'USD',
        'owner_capital',
        'Overdraw the bank',
        [
            new JournalLine('3000', Money::of(100000000000, 'USD'), Money::zero('USD')),
            new JournalLine('1010', Money::zero('USD'), Money::of(100000000000, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_INVALID', static fn (): mixed => $poster->post(new Posting(
        '',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Missing key',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:blank',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        '',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:date',
        '09-12-2026',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Bad date',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:time',
        '2026-09-12',
        '2026-09-12 18:00:00',
        'USD',
        'owner_capital',
        'Bad time',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:reversal',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Reversal',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
        null,
        true,
        '',
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:both',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Both sides',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::of(100, 'USD')),
            new JournalLine('3000', Money::zero('USD'), Money::of(100, 'USD')),
        ],
    )));
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
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
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
        'je:proof:line-cad',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Line currency',
        [
            new JournalLine('1010', Money::of(100, 'CAD'), Money::zero('CAD')),
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
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:payable-credit',
        '2026-09-12',
        '2026-09-12T18:01:00.000Z',
        'USD',
        'owner_capital',
        'Payable credit',
        [
            new JournalLine('1010', Money::of(100, 'USD'), Money::zero('USD')),
            new JournalLine('2000', Money::zero('USD'), Money::of(100, 'USD'), 'party', $party),
        ],
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:party',
        '2026-09-12',
        '2026-09-12T18:02:00.000Z',
        'USD',
        'payable_rent_settlement',
        'Named apply',
        [
            new JournalLine('2000', Money::of(100, 'USD'), Money::zero('USD'), 'party', $party),
            new JournalLine('1300', Money::zero('USD'), Money::of(100, 'USD'), 'party', $party),
        ],
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:negative',
        '2026-09-12',
        '2026-09-12T18:03:00.000Z',
        'USD',
        'holder_payout',
        'Overpay',
        [
            new JournalLine('2000', Money::of(1, 'USD'), Money::zero('USD'), 'party', $party),
            new JournalLine('1010', Money::zero('USD'), Money::of(1, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:receipt',
        '2026-09-12',
        '2026-09-12T18:04:00.000Z',
        'USD',
        'rent_receipt',
        'Receipt with no receipt row',
        [
            new JournalLine('1000', Money::of(10, 'USD'), Money::zero('USD')),
            new JournalLine('1300', Money::zero('USD'), Money::of(10, 'USD'), 'party', $party),
        ],
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:sale-label',
        '2026-09-12',
        '2026-09-12T18:05:00.000Z',
        'USD',
        'sale',
        'Sale label with no ticket',
        [
            new JournalLine('1000', Money::of(110, 'USD'), Money::zero('USD')),
            new JournalLine('2000', Money::zero('USD'), Money::of(100, 'USD'), 'party', $party),
            new JournalLine('6150', Money::zero('USD'), Money::of(10, 'USD')),
        ],
    )));
    expectCode($poster, 'JOURNAL_LINE_INVALID', static fn (): mixed => $poster->post(new Posting(
        'je:proof:cash-income',
        '2026-09-12',
        '2026-09-12T18:06:00.000Z',
        'USD',
        'owner_capital',
        'Cash to income',
        [
            new JournalLine('1000', Money::of(10, 'USD'), Money::zero('USD')),
            new JournalLine('4000', Money::zero('USD'), Money::of(10, 'USD')),
        ],
    )));
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
    $update = $pdo->prepare("UPDATE accounting_periods SET status = 'soft_closed' WHERE starts_on = '2026-09-01'");
    $update->execute();
    expectCode($poster, 'PERIOD_REVIEW', static fn (): mixed => $poster->post(new Posting(
        'je:proof:review',
        '2026-09-12',
        '2026-09-12T18:00:00.000Z',
        'USD',
        'owner_capital',
        'Month in review',
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
if ((string) $count !== (string) $journalsBefore) {
    throw new RuntimeException('Demo journals changed');
}
fwrite(STDOUT, "ledger holds\n");
}

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

if (PHP_SAPI === 'cli' && realpath((string) ($_SERVER['SCRIPT_FILENAME'] ?? '')) === __FILE__) {
    try {
        proveLedger();
    } catch (Throwable $error) {
        fwrite(STDERR, $error->getMessage() . "\n");
        exit(1);
    }
}
