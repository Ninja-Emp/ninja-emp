<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Http\App;
use EmpPos\Http\Request;
use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\Migrator;

function proveHttp(): void
{
$pdo = Database::connectFromEnv();
if ($pdo->query('SELECT current_database()')->fetchColumn() !== 'emp_pos') {
    fail('HTTP proof refuses to write outside emp_pos');
}
$app = new App($pdo, new Migrator($pdo, dirname(__DIR__)));
$slug = 'contract-proof';
cleanup($pdo, $slug);
try {

$csrf = $app->handle(new Request('GET', '/api/v1/csrf', [], [], ''));
$token = (string) ($csrf->body()['csrfToken'] ?? '');
$csrfCookie = cookieValue($csrf, 'csrf');
if ($csrf->status() !== 200 || $token === '' || $token !== $csrfCookie) {
    fail('CSRF was not issued');
}

$signup = $app->handle(new Request('POST', '/api/v1/signup', ['x-csrf-token' => $token], ['csrf' => $csrfCookie], json_encode([
    'email' => 'owner@contract.test',
    'password' => 'practice1',
    'storeName' => 'Contract Proof',
    'slug' => $slug,
], JSON_THROW_ON_ERROR)));
$session = cookieValue($signup, 'session');
if ($signup->status() !== 201 || $session === '') {
    fail('Signup failed ' . json_encode($signup->body()));
}

$seen = $app->handle(new Request('GET', '/api/v1/session', [], ['session' => $session], ''));
if ($seen->status() !== 200 || ($seen->body()['slug'] ?? '') !== $slug || array_key_exists('schema', $seen->body() ?? [])) {
    fail('Session was not readable');
}

$cookies = ['session' => $session, 'csrf' => $csrfCookie];
$headers = ['x-csrf-token' => $token];
$posted = $app->handle(new Request('POST', '/api/v1/journals', $headers, $cookies, json_encode([
    'postingKey' => 'je:contract:opening',
    'postingDate' => '2026-09-12',
    'occurredAt' => '2026-09-12T18:00:00.000Z',
    'currency' => 'USD',
    'sourceType' => 'owner_capital',
    'description' => 'Contract proof',
    'lines' => [
        ['accountCode' => '1010', 'debitMinor' => '100', 'creditMinor' => '0'],
        ['accountCode' => '3000', 'debitMinor' => '0', 'creditMinor' => '100'],
    ],
], JSON_THROW_ON_ERROR)));
if ($posted->status() !== 201 || ($posted->body()['reused'] ?? true) !== false) {
    fail('Journal was not created ' . json_encode($posted->body()));
}
$again = $app->handle(new Request('POST', '/api/v1/journals', $headers, $cookies, json_encode([
    'postingKey' => 'je:contract:opening',
    'postingDate' => '2026-09-12',
    'occurredAt' => '2026-09-12T18:00:00.000Z',
    'currency' => 'USD',
    'sourceType' => 'owner_capital',
    'description' => 'Contract proof',
    'lines' => [
        ['accountCode' => '1010', 'debitMinor' => '100', 'creditMinor' => '0'],
        ['accountCode' => '3000', 'debitMinor' => '0', 'creditMinor' => '100'],
    ],
], JSON_THROW_ON_ERROR)));
if ($again->status() !== 200 || ($again->body()['journalId'] ?? '') !== ($posted->body()['journalId'] ?? '')) {
    fail('Posting key was not idempotent');
}
$loaded = $app->handle(new Request('GET', '/api/v1/journals/' . $posted->body()['journalId'], [], $cookies, ''));
if ($loaded->status() !== 200 || count($loaded->body()['lines'] ?? []) !== 2) {
    fail('Journal was not readable');
}
$trial = $app->handle(new Request('GET', '/api/v1/books/trial-balance', [], $cookies, ''));
if ($trial->status() !== 200 || ($trial->body()['totalDebitMinor'] ?? '') !== ($trial->body()['totalCreditMinor'] ?? '')) {
    fail('Trial balance did not balance');
}
$missing = $app->handle(new Request('GET', '/api/v1/session', [], [], ''));
if ($missing->status() !== 401) {
    fail('Anonymous session was allowed');
}

$schema = $pdo->prepare('SELECT schema_name FROM public.tenants WHERE slug = ?');
$schema->execute([$slug]);
$schemaName = $schema->fetchColumn();
if (!is_string($schemaName)) {
    fail('Store schema was not created');
}
$pdo->exec('SET search_path TO "' . $schemaName . '", public');
$house = $pdo->query("SELECT party_id::text FROM parties WHERE display_name = 'House'")->fetchColumn();
if (!is_string($house)) {
    fail('House party is missing');
}
$audit = $pdo->prepare("SELECT count(*) FROM audit_events WHERE action = 'journal.post' AND resource_id = ?");
$audit->execute([$posted->body()['journalId']]);
if ((string) $audit->fetchColumn() !== '1') {
    fail('Journal post did not write an audit row');
}

$badMoney = journal($app, $headers, $cookies, 'je:contract:bad-money', 'owner_capital', [
    ['accountCode' => '1010', 'debitMinor' => '100.9', 'creditMinor' => '0'],
    ['accountCode' => '3000', 'debitMinor' => '0', 'creditMinor' => '100'],
]);
if ($badMoney->status() !== 400 || ($badMoney->body()['errorCode'] ?? '') !== 'INVALID_MONEY') {
    fail('Non-digit money was accepted ' . json_encode($badMoney->body()));
}

$receipt = journal($app, $headers, $cookies, 'je:contract:receipt', 'rent_receipt', [
    ['accountCode' => '1000', 'debitMinor' => '100', 'creditMinor' => '0'],
    ['accountCode' => '1300', 'debitMinor' => '0', 'creditMinor' => '50', 'subledgerType' => 'party', 'subledgerRef' => $house],
    ['accountCode' => '2000', 'debitMinor' => '0', 'creditMinor' => '50', 'subledgerType' => 'party', 'subledgerRef' => $house],
]);
if ($receipt->status() !== 400 || ($receipt->body()['errorCode'] ?? '') !== 'JOURNAL_LINE_INVALID') {
    fail('Rent receipt touching payable was accepted ' . json_encode($receipt->body()));
}

$apply = journal($app, $headers, $cookies, 'je:contract:fake-apply', 'owner_capital', [
    ['accountCode' => '2000', 'debitMinor' => '50', 'creditMinor' => '0', 'subledgerType' => 'party', 'subledgerRef' => $house],
    ['accountCode' => '1300', 'debitMinor' => '0', 'creditMinor' => '50', 'subledgerType' => 'party', 'subledgerRef' => $house],
]);
if ($apply->status() !== 400 || ($apply->body()['errorCode'] ?? '') !== 'JOURNAL_LINE_INVALID') {
    fail('Unnamed apply was accepted ' . json_encode($apply->body()));
}

$credit = journal($app, $headers, $cookies, 'je:contract:payable', 'owner_capital', [
    ['accountCode' => '1010', 'debitMinor' => '40', 'creditMinor' => '0'],
    ['accountCode' => '2000', 'debitMinor' => '0', 'creditMinor' => '40', 'subledgerType' => 'party', 'subledgerRef' => $house],
]);
if ($credit->status() !== 201) {
    fail('Payable credit was refused ' . json_encode($credit->body()));
}
$overpay = journal($app, $headers, $cookies, 'je:contract:overpay', 'holder_payout', [
    ['accountCode' => '2000', 'debitMinor' => '50', 'creditMinor' => '0', 'subledgerType' => 'party', 'subledgerRef' => $house],
    ['accountCode' => '1010', 'debitMinor' => '0', 'creditMinor' => '50'],
]);
if ($overpay->status() !== 400 || ($overpay->body()['errorCode'] ?? '') !== 'PAYABLE_NEGATIVE') {
    fail('Negative payable was accepted ' . json_encode($overpay->body()));
}

$cashierHash = password_hash('practice1', PASSWORD_ARGON2ID, ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1]);
$pdo->prepare('INSERT INTO public.identities (email, password_hash) VALUES (?, ?)')->execute(['cashier@contract.test', $cashierHash]);
$pdo->prepare(
    "INSERT INTO public.tenant_memberships (tenant_id, identity_id, role)
     SELECT t.tenant_id, i.identity_id, 'cashier' FROM public.tenants t, public.identities i WHERE t.slug = ? AND i.email = ?",
)->execute([$slug, 'cashier@contract.test']);
$cashierLogin = $app->handle(new Request('POST', '/api/v1/login', $headers, ['csrf' => $csrfCookie], json_encode([
    'email' => 'cashier@contract.test',
    'password' => 'practice1',
], JSON_THROW_ON_ERROR)));
$cashierSession = cookieValue($cashierLogin, 'session');
if ($cashierLogin->status() !== 200 || $cashierSession === '') {
    fail('Cashier login failed ' . json_encode($cashierLogin->body()));
}
$cashierPost = journal($app, $headers, ['session' => $cashierSession, 'csrf' => $csrfCookie], 'je:contract:cashier', 'owner_capital', [
    ['accountCode' => '1010', 'debitMinor' => '10', 'creditMinor' => '0'],
    ['accountCode' => '3000', 'debitMinor' => '0', 'creditMinor' => '10'],
]);
if ($cashierPost->status() !== 403 || ($cashierPost->body()['errorCode'] ?? '') !== 'FORBIDDEN') {
    fail('Cashier journal was accepted ' . json_encode($cashierPost->body()));
}

$pdo->prepare('UPDATE public.identities SET disabled_at = now() WHERE email = ?')->execute(['owner@contract.test']);
$disabled = $app->handle(new Request('GET', '/api/v1/session', [], ['session' => $session], ''));
if ($disabled->status() !== 401) {
    fail('Disabled session was accepted');
}
$pdo->prepare('UPDATE public.identities SET disabled_at = NULL WHERE email = ?')->execute(['owner@contract.test']);

$duplicate = $app->handle(new Request('POST', '/api/v1/signup', $headers, ['csrf' => $csrfCookie], json_encode([
    'email' => 'other@contract.test',
    'password' => 'practice1',
    'storeName' => 'Other',
    'slug' => $slug,
], JSON_THROW_ON_ERROR)));
if ($duplicate->status() !== 409 || ($duplicate->body()['errorCode'] ?? '') !== 'SLUG_TAKEN') {
    fail('Duplicate slug was not refused ' . json_encode($duplicate->body()));
}

fwrite(STDOUT, "http holds\n");
} finally {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }
    cleanup($pdo, $slug);
}
}

function journal(EmpPos\Http\App $app, array $headers, array $cookies, string $key, string $source, array $lines): EmpPos\Http\Response
{
    return $app->handle(new EmpPos\Http\Request('POST', '/api/v1/journals', $headers, $cookies, json_encode([
        'postingKey' => $key,
        'postingDate' => '2026-09-12',
        'occurredAt' => '2026-09-12T18:00:00.000Z',
        'currency' => 'USD',
        'sourceType' => $source,
        'description' => 'Contract proof',
        'lines' => $lines,
    ], JSON_THROW_ON_ERROR)));
}

function cookieValue(EmpPos\Http\Response $response, string $name): string
{
    foreach ($response->cookies() as $cookie) {
        if ($cookie['name'] === $name) {
            return $cookie['value'];
        }
    }
    return '';
}

function cleanup(PDO $pdo, string $slug): void
{
    $select = $pdo->prepare('SELECT schema_name FROM public.tenants WHERE slug = ?');
    $select->execute([$slug]);
    $schema = $select->fetchColumn();
    if (is_string($schema) && preg_match('/^tenant_[0-9a-f_]+$/', $schema) === 1) {
        $pdo->exec('DROP SCHEMA "' . $schema . '" CASCADE');
        $pdo->prepare('DELETE FROM public.schema_migrations WHERE migration_key LIKE ?')->execute(['tenant:' . $schema . ':%']);
    }
    $pdo->prepare(
        'DELETE FROM public.tenant_sessions WHERE tenant_membership_id IN (
            SELECT m.tenant_membership_id FROM public.tenant_memberships m JOIN public.tenants t ON t.tenant_id = m.tenant_id WHERE t.slug = ?
        )',
    )->execute([$slug]);
    $pdo->prepare('DELETE FROM public.tenant_billing WHERE tenant_id IN (SELECT tenant_id FROM public.tenants WHERE slug = ?)')->execute([$slug]);
    $pdo->prepare('DELETE FROM public.tenant_memberships WHERE tenant_id IN (SELECT tenant_id FROM public.tenants WHERE slug = ?)')->execute([$slug]);
    $pdo->prepare('DELETE FROM public.identities WHERE email = ? OR email = ?')->execute(['owner@contract.test', 'cashier@contract.test']);
    $pdo->prepare('DELETE FROM public.tenants WHERE slug = ?')->execute([$slug]);
}

function fail(string $message): never
{
    throw new RuntimeException($message);
}

if (PHP_SAPI === 'cli' && realpath((string) ($_SERVER['SCRIPT_FILENAME'] ?? '')) === __FILE__) {
    try {
        proveHttp();
    } catch (RuntimeException $error) {
        fwrite(STDERR, $error->getMessage() . "\n");
        exit(1);
    }
}
