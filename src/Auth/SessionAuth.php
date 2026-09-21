<?php

declare(strict_types=1);

namespace NinjaEMP\Auth;

/**
 * Session-backed authentication. Stores only the user id, role and tenant id in
 * the session; the full user is rehydrated on demand. Session id is regenerated
 * on login to defeat fixation.
 */
final class SessionAuth
{
    private const KEY = 'nem_user';

    public function __construct(private readonly string $sessionKey = self::KEY)
    {
    }

    public function login(User $user): void
    {
        if (session_status() === PHP_SESSION_ACTIVE) {
            session_regenerate_id(true);
        }

        $_SESSION[$this->sessionKey] = [
            'id' => $user->id,
            'name' => $user->name,
            'role' => $user->role->code(),
            'tenant_id' => $user->tenantId,
        ];
    }

    public function logout(): void
    {
        unset($_SESSION[$this->sessionKey]);

        if (session_status() === PHP_SESSION_ACTIVE) {
            session_regenerate_id(true);
        }
    }

    public function check(): bool
    {
        return isset($_SESSION[$this->sessionKey]['id']);
    }

    public function user(): ?User
    {
        $data = $_SESSION[$this->sessionKey] ?? null;

        if (!is_array($data) || !isset($data['id'], $data['role'], $data['tenant_id'])) {
            return null;
        }

        if (!Role::isValid((string) $data['role'])) {
            return null;
        }

        return new User(
            (string) $data['id'],
            (string) ($data['name'] ?? 'User'),
            Role::of((string) $data['role']),
            (string) $data['tenant_id'],
        );
    }

    public function can(string $permission): bool
    {
        return $this->user()?->can($permission) ?? false;
    }
}
