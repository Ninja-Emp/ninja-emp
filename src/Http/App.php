<?php

declare(strict_types=1);

namespace EmpPos\Http;

use EmpPos\Feature\Identity\IdentityService;
use EmpPos\Shared\Ledger\JournalLine;
use EmpPos\Shared\Ledger\LedgerError;
use EmpPos\Shared\Ledger\LedgerPoster;
use EmpPos\Shared\Ledger\Money;
use EmpPos\Shared\Ledger\Posting;
use EmpPos\Shared\Ledger\TrialBalance;
use EmpPos\Shared\Persistence\Migrator;
use PDO;

final class App
{
    private IdentityService $identity;

    public function __construct(
        private readonly PDO $pdo,
        Migrator $migrator,
    ) {
        $this->identity = new IdentityService($pdo, $migrator);
    }

    public function handle(Request $request): Response
    {
        $path = $request->path();
        if ($request->method() === 'GET' && $path === '/api/v1/csrf') {
            return $this->from($this->identity->csrf($request->cookie('csrf')));
        }
        if ($request->method() === 'POST' && $this->csrfRejected($request)) {
            return Response::json(403, ['errorCode' => 'CSRF_INVALID', 'message' => 'CSRF token does not match']);
        }
        if ($request->method() === 'POST' && $path === '/api/v1/signup') {
            return $this->from($this->identity->signup($request->json()));
        }
        if ($request->method() === 'POST' && $path === '/api/v1/login') {
            return $this->from($this->identity->login($request->json()));
        }
        $member = $this->identity->membership($request->cookie('session'));
        if ($request->method() === 'POST' && $path === '/api/v1/logout') {
            return $this->from($this->identity->logout($request->cookie('session')));
        }
        if ($request->method() === 'GET' && $path === '/api/v1/session') {
            return $this->from($this->identity->session($request->cookie('session')));
        }
        if ($member === null) {
            return Response::json(401, ['errorCode' => 'UNAUTHORIZED', 'message' => 'Sign in required']);
        }
        $this->pdo->exec('SET search_path TO "' . $this->schema($member['schema']) . '", public');
        try {
            if ($request->method() === 'POST' && $path === '/api/v1/journals') {
                return $this->postJournal($request);
            }
            if ($request->method() === 'GET' && str_starts_with($path, '/api/v1/journals/')) {
                return $this->getJournal(substr($path, strlen('/api/v1/journals/')));
            }
            if ($request->method() === 'GET' && $path === '/api/v1/books/trial-balance') {
                return Response::json(200, (new TrialBalance($this->pdo))->report());
            }
        } catch (LedgerError $error) {
            $status = in_array($error->errorCode(), ['PERIOD_CLOSED', 'PERIOD_REVIEW'], true) ? 409 : 400;
            if (in_array($error->errorCode(), ['JOURNAL_FAILED', 'BOOK_MISSING', 'ACCOUNT_MISSING', 'TRIAL_BALANCE_DRIFT', 'PERIOD_FAILED'], true)) {
                $status = 500;
            }
            return Response::json($status, ['errorCode' => $error->errorCode(), 'message' => $error->getMessage()]);
        }
        return Response::json(404, ['errorCode' => 'NOT_FOUND', 'message' => 'Not found']);
    }

    private function postJournal(Request $request): Response
    {
        $body = $request->json();
        $currency = (string) ($body['currency'] ?? '');
        $lines = [];
        foreach ($body['lines'] ?? [] as $line) {
            if (!is_array($line)) {
                continue;
            }
            $lines[] = new JournalLine(
                (string) ($line['accountCode'] ?? ''),
                Money::of((int) ($line['debitMinor'] ?? 0), $currency),
                Money::of((int) ($line['creditMinor'] ?? 0), $currency),
                isset($line['subledgerType']) ? (string) $line['subledgerType'] : null,
                isset($line['subledgerRef']) ? (string) $line['subledgerRef'] : null,
                isset($line['memo']) ? (string) $line['memo'] : null,
            );
        }
        $ownsTransaction = !$this->pdo->inTransaction();
        if ($ownsTransaction) {
            $this->pdo->beginTransaction();
        }
        try {
        $posted = (new LedgerPoster($this->pdo))->post(new Posting(
            (string) ($body['postingKey'] ?? ''),
            (string) ($body['postingDate'] ?? ''),
            (string) ($body['occurredAt'] ?? ''),
            $currency,
            (string) ($body['sourceType'] ?? ''),
            (string) ($body['description'] ?? ''),
            $lines,
            isset($body['sourceReference']) ? (string) $body['sourceReference'] : null,
            ($body['reversal'] ?? false) === true,
            isset($body['reversesJournalId']) ? (string) $body['reversesJournalId'] : null,
        ));
        } catch (LedgerError $error) {
            if ($ownsTransaction && $this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }
            throw $error;
        }
        if ($ownsTransaction) {
            $this->pdo->commit();
        }
        return Response::json($posted->reused() ? 200 : 201, [
            'journalId' => $posted->journalId(),
            'journalNo' => $posted->journalNo(),
            'postingKey' => $posted->postingKey(),
            'reused' => $posted->reused(),
        ]);
    }

    private function getJournal(string $journalId): Response
    {
        $select = $this->pdo->prepare(
            "SELECT journal_id::text AS journal_id, journal_no::text AS journal_no, posting_key, posting_date::text AS posting_date,
                    to_char(occurred_at AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"') AS occurred_at,
                    currency, source_type, source_reference, description, is_reversal, reverses_journal_id::text AS reverses_journal_id
             FROM journals WHERE journal_id = ?",
        );
        $select->execute([$journalId]);
        $row = $select->fetch();
        if ($row === false) {
            return Response::json(404, ['errorCode' => 'JOURNAL_MISSING', 'message' => 'Journal was not found']);
        }
        $lines = $this->pdo->prepare(
            'SELECT a.code, l.debit_minor::text AS debit_minor, l.credit_minor::text AS credit_minor, l.subledger_type, l.subledger_ref::text AS subledger_ref
             FROM journal_lines l JOIN accounts a ON a.account_id = l.account_id WHERE l.journal_id = ? ORDER BY l.line_no',
        );
        $lines->execute([$journalId]);
        return Response::json(200, [
            'journalId' => (string) $row['journal_id'],
            'journalNo' => (string) $row['journal_no'],
            'postingKey' => (string) $row['posting_key'],
            'postingDate' => (string) $row['posting_date'],
            'occurredAt' => (string) $row['occurred_at'],
            'currency' => rtrim((string) $row['currency']),
            'sourceType' => (string) $row['source_type'],
            'sourceReference' => $row['source_reference'],
            'description' => (string) $row['description'],
            'reversal' => $row['is_reversal'] === true || $row['is_reversal'] === 't',
            'reversesJournalId' => $row['reverses_journal_id'],
            'lines' => array_map(static fn (array $line): array => [
                'accountCode' => (string) $line['code'],
                'debitMinor' => (string) $line['debit_minor'],
                'creditMinor' => (string) $line['credit_minor'],
                'subledgerType' => $line['subledger_type'],
                'subledgerRef' => $line['subledger_ref'],
            ], $lines->fetchAll()),
        ]);
    }

    private function csrfRejected(Request $request): bool
    {
        $cookie = $request->cookie('csrf');
        return $cookie === '' || !hash_equals($cookie, $request->header('x-csrf-token'));
    }

    private function schema(string $schema): string
    {
        if (preg_match('/^tenant_[0-9a-f_]+$/', $schema) !== 1) {
            throw new LedgerError('JOURNAL_FAILED', 'Store schema is not valid');
        }
        return $schema;
    }

    /**
     * @param array{status: int, body: array<string, mixed>|null, cookies: list<array{name: string, value: string, clear: bool}>} $result
     */
    private function from(array $result): Response
    {
        if ($result['body'] === null) {
            return Response::empty($result['status'], $result['cookies']);
        }
        return Response::json($result['status'], $result['body'], $result['cookies']);
    }
}
