<?php

declare(strict_types=1);

$path = dirname(__DIR__) . '/docs/openapi/ledger.openapi.json';
$raw = file_get_contents($path);
if ($raw === false) {
    fwrite(STDERR, "OpenAPI file is missing\n");
    exit(1);
}
$decoded = json_decode($raw, true);
if (!is_array($decoded)) {
    fwrite(STDERR, "OpenAPI file is not JSON\n");
    exit(1);
}

/** @var array<string, mixed> $doc */
$doc = $decoded;
requireString($doc, 'openapi', '3.1.0');

$paths = requireArray($doc, 'paths');
$post = requireOperation($paths, '/journals', 'post');
$get = requireOperation($paths, '/journals/{journalId}', 'get');
$trial = requireOperation($paths, '/books/trial-balance', 'get');

requireResponse($post, '201');
requireResponse($post, '200');
requireResponse($post, '401');
requireResponse($get, '200');
requireResponse($get, '404');
requireResponse($get, '401');
requireResponse($trial, '200');
requireResponse($trial, '500');
requireResponse($trial, '401');

$components = requireArray($doc, 'components');
$schemas = requireArray($components, 'schemas');
$journalPost = requireArray($schemas, 'JournalPost');
$required = $journalPost['required'] ?? null;
if (!is_array($required)) {
    fail('JournalPost required fields are missing');
}
foreach (['postingKey', 'postingDate', 'occurredAt', 'currency', 'sourceType', 'description', 'lines'] as $field) {
    if (!in_array($field, $required, true)) {
        fail('JournalPost is missing ' . $field);
    }
}

$properties = requireArray($journalPost, 'properties');
foreach (['sourceReference', 'reversal', 'reversesJournalId'] as $field) {
    if (!isset($properties[$field])) {
        fail('JournalPost is missing ' . $field);
    }
}

$line = requireArray($schemas, 'JournalLine');
$lineRequired = $line['required'] ?? null;
if (!is_array($lineRequired)) {
    fail('JournalLine required fields are missing');
}
foreach (['accountCode', 'debitMinor', 'creditMinor'] as $field) {
    if (!in_array($field, $lineRequired, true)) {
        fail('JournalLine is missing ' . $field);
    }
}

$error = requireArray($schemas, 'Error');
$errorProps = requireArray($error, 'properties');
$code = requireArray($errorProps, 'errorCode');
$enum = $code['enum'] ?? null;
if (!is_array($enum)) {
    fail('Error codes are missing');
}
foreach ([
    'JOURNAL_UNBALANCED',
    'JOURNAL_LINE_INVALID',
    'JOURNAL_INVALID',
    'ACCOUNT_MISSING',
    'ACCOUNT_NOT_POSTABLE',
    'CURRENCY_MISMATCH',
    'INVALID_MONEY',
    'BOOK_MISSING',
    'PERIOD_CLOSED',
    'PERIOD_REVIEW',
    'JOURNAL_FAILED',
    'TRIAL_BALANCE_DRIFT',
] as $errorCode) {
    if (!in_array($errorCode, $enum, true)) {
        fail('Error code ' . $errorCode . ' is missing');
    }
}

$security = $doc['security'] ?? null;
if (!is_array($security) || $security === []) {
    fail('A store session is not required');
}

fwrite(STDOUT, "openapi holds\n");

/**
 * @param array<string, mixed> $doc
 */
function requireString(array $doc, string $key, string $expected): void
{
    if (($doc[$key] ?? null) !== $expected) {
        fail($key . ' is not ' . $expected);
    }
}

/**
 * @param array<string, mixed> $doc
 * @return array<string, mixed>
 */
function requireArray(array $doc, string $key): array
{
    $value = $doc[$key] ?? null;
    if (!is_array($value)) {
        fail($key . ' is missing');
    }
    /** @var array<string, mixed> $value */
    return $value;
}

/**
 * @param array<string, mixed> $paths
 * @return array<string, mixed>
 */
function requireOperation(array $paths, string $path, string $method): array
{
    $item = $paths[$path] ?? null;
    if (!is_array($item)) {
        fail($path . ' is missing');
    }
    $operation = $item[$method] ?? null;
    if (!is_array($operation)) {
        fail($method . ' ' . $path . ' is missing');
    }
    /** @var array<string, mixed> $operation */
    return $operation;
}

/**
 * @param array<string, mixed> $operation
 */
function requireResponse(array $operation, string $status): void
{
    $responses = $operation['responses'] ?? null;
    if (!is_array($responses) || !isset($responses[$status])) {
        fail('Response ' . $status . ' is missing');
    }
}

function fail(string $message): never
{
    fwrite(STDERR, $message . "\n");
    exit(1);
}
