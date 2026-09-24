<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Http\App;
use EmpPos\Http\Request;
use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\Migrator;

$pdo = Database::connectFromEnv();
if ($pdo->query('SELECT current_database()')->fetchColumn() !== 'emp_pos') {
    fwrite(STDERR, "HTTP proof refuses to write outside emp_pos\n");
    exit(1);
}
$app = new App($pdo, new Migrator($pdo, dirname(__DIR__)));
$slug = 'contract-proof';
cleanup($pdo, $slug);

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
if ($seen->status() !== 200 || ($seen->body()['slug'] ?? '') !== $slug) {
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

cleanup($pdo, $slug);
fwrite(STDOUT, "http holds\n");

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
    $pdo->prepare('DELETE FROM public.identities WHERE email = ?')->execute(['owner@contract.test']);
    $pdo->prepare('DELETE FROM public.tenants WHERE slug = ?')->execute([$slug]);
}

function fail(string $message): never
{
    fwrite(STDERR, $message . "\n");
    exit(1);
}

register_shutdown_function(static function () use ($pdo, $slug): void {
    if ($pdo->inTransaction()) {
        $pdo->rollBack();
    }
    cleanup($pdo, $slug);
});
