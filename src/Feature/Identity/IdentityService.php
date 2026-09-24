<?php

declare(strict_types=1);

namespace EmpPos\Feature\Identity;

use EmpPos\Shared\Persistence\Migrator;
use PDO;
use PDOException;

final class IdentityService
{
    public function __construct(
        private readonly PDO $pdo,
        private readonly Migrator $migrator,
    ) {
    }

    /**
     * @return array{status: int, body: array<string, mixed>, cookies: list<array{name: string, value: string, clear: bool}>}
     */
    public function csrf(string $existing): array
    {
        $token = $existing !== '' ? $existing : bin2hex(random_bytes(32));
        return ['status' => 200, 'body' => ['csrfToken' => $token], 'cookies' => [$this->cookie('csrf', $token, false)]];
    }

    /**
     * @param array<string, mixed> $body
     * @return array{status: int, body: array<string, mixed>|null, cookies: list<array{name: string, value: string, clear: bool}>}
     */
    public function signup(array $body): array
    {
        $email = strtolower(trim((string) ($body['email'] ?? '')));
        $password = (string) ($body['password'] ?? '');
        $storeName = trim((string) ($body['storeName'] ?? ''));
        $slug = strtolower(trim((string) ($body['slug'] ?? '')));
        $currency = (string) ($body['currency'] ?? 'USD');
        $timezone = (string) ($body['timezone'] ?? 'America/Chicago');
        if (!in_array($currency, ['USD', 'CAD', 'EUR'], true)) {
            return $this->error(400, 'INVALID_EMAIL', 'Currency is not supported');
        }
        if (filter_var($email, FILTER_VALIDATE_EMAIL) === false) {
            return $this->error(400, 'INVALID_EMAIL', 'Email is not valid');
        }
        if (strlen($password) < 8) {
            return $this->error(400, 'INVALID_PASSWORD', 'Password must be at least 8 characters');
        }
        if ($storeName === '' || preg_match('/^[a-z0-9]+(?:-[a-z0-9]+)*$/', $slug) !== 1) {
            return $this->error(400, 'INVALID_EMAIL', 'Store name and slug are required');
        }
        $emailTaken = $this->pdo->prepare('SELECT 1 FROM public.identities WHERE email = ?');
        $emailTaken->execute([$email]);
        if ($emailTaken->fetch() !== false) {
            return $this->error(409, 'EMAIL_TAKEN', 'That email is already registered');
        }
        $slugTaken = $this->pdo->prepare('SELECT 1 FROM public.tenants WHERE slug = ?');
        $slugTaken->execute([$slug]);
        if ($slugTaken->fetch() !== false) {
            return $this->error(409, 'SLUG_TAKEN', 'That store address is taken');
        }
        $owns = !$this->pdo->inTransaction();
        if ($owns) {
            $this->migrator->migrateShared();
            $this->pdo->beginTransaction();
        }
        try {
            $hash = password_hash($password, PASSWORD_ARGON2ID, ['memory_cost' => 19456, 'time_cost' => 2, 'threads' => 1]);
            $identity = $this->pdo->prepare('INSERT INTO public.identities (email, password_hash) VALUES (?, ?) RETURNING identity_id::text AS identity_id');
            $identity->execute([$email, $hash]);
            $identityId = (string) $identity->fetch()['identity_id'];
            $tenant = $this->pdo->prepare(
                "INSERT INTO public.tenants (slug, store_name, status, use_case, functional_currency, timezone) VALUES (?, ?, 'live', 'vendor_mall', ?, ?) RETURNING tenant_id::text AS tenant_id, schema_name",
            );
            $tenant->execute([$slug, $storeName, $currency, $timezone]);
            $tenantRow = $tenant->fetch();
            $tenantId = (string) $tenantRow['tenant_id'];
            $schema = (string) $tenantRow['schema_name'];
            $membership = $this->pdo->prepare(
                "INSERT INTO public.tenant_memberships (tenant_id, identity_id, role) VALUES (?, ?, 'owner') RETURNING tenant_membership_id::text AS tenant_membership_id",
            );
            $membership->execute([$tenantId, $identityId]);
            $membershipId = (string) $membership->fetch()['tenant_membership_id'];
            $this->pdo->prepare('INSERT INTO public.tenant_billing (tenant_id, plan_code, status) VALUES (?, ?, ?)')->execute([$tenantId, 'practice', 'trial']);
            $this->migrator->applyTenant($schema);
            $this->pdo->prepare(
                "INSERT INTO ledger_books (code, name, currency, is_default) VALUES ('PRIMARY', 'Primary book', ?, true)",
            )->execute([$currency]);
            $token = $this->startSession($membershipId);
            if ($owns) {
                $this->pdo->commit();
            }
            return [
                'status' => 201,
                'body' => ['identityId' => $identityId, 'tenantId' => $tenantId, 'slug' => $slug, 'role' => 'owner'],
                'cookies' => [$this->cookie('session', $token, false)],
            ];
        } catch (PDOException $error) {
            if ($owns && $this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }
            throw $error;
        }
    }

    /**
     * @param array<string, mixed> $body
     * @return array{status: int, body: array<string, mixed>|null, cookies: list<array{name: string, value: string, clear: bool}>}
     */
    public function login(array $body): array
    {
        $email = strtolower(trim((string) ($body['email'] ?? '')));
        $password = (string) ($body['password'] ?? '');
        $select = $this->pdo->prepare(
            "SELECT i.identity_id::text AS identity_id, i.password_hash, m.tenant_membership_id::text AS tenant_membership_id, m.role, t.tenant_id::text AS tenant_id, t.slug
             FROM public.identities i
             JOIN public.tenant_memberships m ON m.identity_id = i.identity_id AND m.disabled_at IS NULL
             JOIN public.tenants t ON t.tenant_id = m.tenant_id
             WHERE i.email = ? AND i.disabled_at IS NULL
             ORDER BY m.created_at
             LIMIT 1",
        );
        $select->execute([$email]);
        $row = $select->fetch();
        if ($row === false || !password_verify($password, (string) $row['password_hash'])) {
            return $this->error(401, 'UNAUTHORIZED', 'Email or password is wrong');
        }
        $token = $this->startSession((string) $row['tenant_membership_id']);
        return [
            'status' => 200,
            'body' => [
                'identityId' => (string) $row['identity_id'],
                'tenantId' => (string) $row['tenant_id'],
                'slug' => (string) $row['slug'],
                'role' => (string) $row['role'],
            ],
            'cookies' => [$this->cookie('session', $token, false)],
        ];
    }

    /**
     * @return array{status: int, body: array<string, mixed>|null, cookies: list<array{name: string, value: string, clear: bool}>}
     */
    public function logout(string $token): array
    {
        $delete = $this->pdo->prepare('DELETE FROM public.tenant_sessions WHERE token_hash = ?');
        $delete->execute([hash('sha256', $token)]);
        return ['status' => 204, 'body' => null, 'cookies' => [$this->cookie('session', '', true)]];
    }

    /**
     * @return array{status: int, body: array<string, mixed>, cookies: list<array{name: string, value: string, clear: bool}>}
     */
    public function session(string $token): array
    {
        $row = $this->membership($token);
        if ($row === null) {
            return $this->error(401, 'UNAUTHORIZED', 'Sign in required');
        }
        return ['status' => 200, 'body' => $row, 'cookies' => []];
    }

    /**
     * @return array{identityId: string, tenantId: string, slug: string, role: string, schema: string}|null
     */
    public function membership(string $token): ?array
    {
        if ($token === '') {
            return null;
        }
        $select = $this->pdo->prepare(
            "SELECT i.identity_id::text AS identity_id, t.tenant_id::text AS tenant_id, t.slug, t.schema_name, m.role
             FROM public.tenant_sessions s
             JOIN public.tenant_memberships m ON m.tenant_membership_id = s.tenant_membership_id
             JOIN public.identities i ON i.identity_id = m.identity_id
             JOIN public.tenants t ON t.tenant_id = m.tenant_id
             WHERE s.token_hash = ? AND s.expires_at > now()",
        );
        $select->execute([hash('sha256', $token)]);
        $row = $select->fetch();
        if ($row === false) {
            return null;
        }
        return [
            'identityId' => (string) $row['identity_id'],
            'tenantId' => (string) $row['tenant_id'],
            'slug' => (string) $row['slug'],
            'role' => (string) $row['role'],
            'schema' => (string) $row['schema_name'],
        ];
    }

    private function startSession(string $membershipId): string
    {
        $token = bin2hex(random_bytes(32));
        $insert = $this->pdo->prepare(
            "INSERT INTO public.tenant_sessions (tenant_membership_id, token_hash, expires_at) VALUES (?, ?, now() + interval '12 hours')",
        );
        $insert->execute([$membershipId, hash('sha256', $token)]);
        return $token;
    }

    /**
     * @return array{name: string, value: string, clear: bool}
     */
    private function cookie(string $name, string $value, bool $clear): array
    {
        return ['name' => $name, 'value' => $value, 'clear' => $clear];
    }

    /**
     * @return array{status: int, body: array<string, mixed>, cookies: list<array{name: string, value: string, clear: bool}>}
     */
    private function error(int $status, string $code, string $message): array
    {
        return ['status' => $status, 'body' => ['errorCode' => $code, 'message' => $message], 'cookies' => []];
    }
}
