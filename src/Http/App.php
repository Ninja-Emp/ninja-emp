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
use EmpPos\Shared\Scalar;
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
                if ($member['role'] === 'cashier') {
                    return Response::json(403, ['errorCode' => 'FORBIDDEN', 'message' => 'A cashier cannot post a journal']);
                }
                return $this->postJournal($request, $member);
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

    /**
     * @param array{identityId: string, tenantId: string, slug: string, role: string, schema: string, membershipId: string} $member
     */
    private function postJournal(Request $request, array $member): Response
    {
        $body = $request->json();
        $currency = Scalar::string($body['currency'] ?? '', 'currency');
        $rawLines = $body['lines'] ?? [];
        if (!is_array($rawLines)) {
            $rawLines = [];
        }
        $lines = [];
        foreach ($rawLines as $line) {
            if (!is_array($line)) {
                continue;
            }
            $lines[] = new JournalLine(
                Scalar::string($line['accountCode'] ?? '', 'accountCode'),
                Money::fromMinorString($this->minor($line['debitMinor'] ?? null), $currency),
                Money::fromMinorString($this->minor($line['creditMinor'] ?? null), $currency),
                isset($line['subledgerType']) ? Scalar::string($line['subledgerType'], 'subledgerType') : null,
                isset($line['subledgerRef']) ? Scalar::string($line['subledgerRef'], 'subledgerRef') : null,
                isset($line['memo']) ? Scalar::string($line['memo'], 'memo') : null,
            );
        }
        $ownsTransaction = !$this->pdo->inTransaction();
        if ($ownsTransaction) {
            $this->pdo->beginTransaction();
        }
        try {
        $posted = (new LedgerPoster($this->pdo))->post(new Posting(
            Scalar::string($body['postingKey'] ?? '', 'postingKey'),
            Scalar::string($body['postingDate'] ?? '', 'postingDate'),
            Scalar::string($body['occurredAt'] ?? '', 'occurredAt'),
            $currency,
            Scalar::string($body['sourceType'] ?? '', 'sourceType'),
            Scalar::string($body['description'] ?? '', 'description'),
            $lines,
            isset($body['sourceReference']) ? Scalar::string($body['sourceReference'], 'sourceReference') : null,
            ($body['reversal'] ?? false) === true,
            isset($body['reversesJournalId']) ? Scalar::string($body['reversesJournalId'], 'reversesJournalId') : null,
        ));
        } catch (LedgerError $error) {
            if ($ownsTransaction && $this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }
            throw $error;
        }
        $this->audit($member, $posted->journalId(), $posted->reused());
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

    private function minor(mixed $value): string
    {
        if (is_int($value)) {
            return (string) $value;
        }
        if (is_string($value)) {
            return $value;
        }
        return '';
    }

    /**
     * @param array{identityId: string, membershipId: string} $member
     */
    private function audit(array $member, string $journalId, bool $reused): void
    {
        if ($reused) {
            return;
        }
        $insert = $this->pdo->prepare(
            "INSERT INTO audit_events (identity_id, membership_id, action, message, resource_type, resource_id, payload)
             VALUES (?, ?, 'journal.post', 'Journal posted', 'journal', ?, '{}'::jsonb)",
        );
        $insert->execute([$member['identityId'], $member['membershipId'], $journalId]);
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
        $fetched = $select->fetch();
        if ($fetched === false) {
            return Response::json(404, ['errorCode' => 'JOURNAL_MISSING', 'message' => 'Journal was not found']);
        }
        $row = Scalar::row($fetched);
        $lines = $this->pdo->prepare(
            'SELECT a.code, l.debit_minor::text AS debit_minor, l.credit_minor::text AS credit_minor, l.subledger_type, l.subledger_ref::text AS subledger_ref
             FROM journal_lines l JOIN accounts a ON a.account_id = l.account_id WHERE l.journal_id = ? ORDER BY l.line_no',
        );
        $lines->execute([$journalId]);
        $fetchedLines = $lines->fetchAll();
        $out = [];
        foreach ($fetchedLines as $line) {
            $item = Scalar::row($line);
            $out[] = [
                'accountCode' => Scalar::text($item, 'code'),
                'debitMinor' => Scalar::text($item, 'debit_minor'),
                'creditMinor' => Scalar::text($item, 'credit_minor'),
                'subledgerType' => Scalar::nullableText($item, 'subledger_type'),
                'subledgerRef' => Scalar::nullableText($item, 'subledger_ref'),
            ];
        }
        return Response::json(200, [
            'journalId' => Scalar::text($row, 'journal_id'),
            'journalNo' => Scalar::text($row, 'journal_no'),
            'postingKey' => Scalar::text($row, 'posting_key'),
            'postingDate' => Scalar::text($row, 'posting_date'),
            'occurredAt' => Scalar::text($row, 'occurred_at'),
            'currency' => rtrim(Scalar::text($row, 'currency')),
            'sourceType' => Scalar::text($row, 'source_type'),
            'sourceReference' => Scalar::nullableText($row, 'source_reference'),
            'description' => Scalar::text($row, 'description'),
            'reversal' => $row['is_reversal'] === true || $row['is_reversal'] === 't',
            'reversesJournalId' => Scalar::nullableText($row, 'reverses_journal_id'),
            'lines' => $out,
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
