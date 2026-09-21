<?php

declare(strict_types=1);

namespace NinjaEMP\Auth;

/**
 * An authenticated principal. Immutable.
 */
final class User
{
    public function __construct(
        public readonly string $id,
        public readonly string $name,
        public readonly Role $role,
        public readonly string $tenantId,
    ) {
    }

    public function can(string $permission): bool
    {
        return $this->role->can($permission);
    }

    public function initials(): string
    {
        $parts = preg_split('/\s+/', trim($this->name)) ?: [];
        $initials = '';

        foreach (array_slice($parts, 0, 2) as $part) {
            if ($part !== '') {
                $initials .= strtoupper($part[0]);
            }
        }

        return $initials !== '' ? $initials : '?';
    }
}
