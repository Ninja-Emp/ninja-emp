<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Support;

/**
 * Mock authentication + RBAC.
 *
 * In the real app this is backed by sessions + party roles (SRS §0.7).
 * Here it is a simple in-memory user with a role, so the UI can demonstrate
 * role-aware navigation and route gating.
 */
final class Auth
{
    /**
     * Permission matrix. Each role maps to the set of permissions it holds.
     * Permissions are coarse module-level capabilities for the UI.
     */
    private const MATRIX = [
        'owner' => [
            'dashboard.view', 'pos.use', 'booths.manage', 'vendors.manage',
            'inventory.manage', 'reports.view', 'settings.manage', 'accounting.view',
        ],
        'manager' => [
            'dashboard.view', 'pos.use', 'booths.manage', 'vendors.manage',
            'inventory.manage', 'reports.view',
        ],
        'accountant' => [
            'dashboard.view', 'vendors.manage', 'reports.view', 'accounting.view',
        ],
        'cashier' => [
            'dashboard.view', 'pos.use',
        ],
    ];

    private const ROLE_LABELS = [
        'owner'      => 'Owner',
        'manager'    => 'Manager',
        'accountant' => 'Accountant',
        'cashier'    => 'Cashier',
    ];

    /** @var array{id:string,name:string,role:string,initials:string}|null */
    private ?array $user = null;

    public function __construct()
    {
        // Default demo user. The login screen can switch roles.
        $this->user = [
            'id'       => 'u-1',
            'name'     => 'Dana Whitfield',
            'role'     => 'owner',
            'initials' => 'DW',
        ];
    }

    public function user(): ?array
    {
        return $this->user;
    }

    public function check(): bool
    {
        return $this->user !== null;
    }

    public function role(): string
    {
        return $this->user['role'] ?? 'cashier';
    }

    public function roleLabel(): string
    {
        return self::ROLE_LABELS[$this->role()] ?? ucfirst($this->role());
    }

    public function loginAs(string $role): void
    {
        if (!isset(self::MATRIX[$role])) {
            return;
        }
        $this->user = [
            'id'       => 'u-' . $role,
            'name'     => match ($role) {
                'owner'      => 'Dana Whitfield',
                'manager'    => 'Marcus Lee',
                'accountant' => 'Priya Nair',
                'cashier'    => 'Sam Ortiz',
                default      => 'Demo User',
            },
            'role'     => $role,
            'initials' => match ($role) {
                'owner'      => 'DW',
                'manager'    => 'ML',
                'accountant' => 'PN',
                'cashier'    => 'SO',
                default      => 'DU',
            },
        ];
    }

    public function can(string $permission): bool
    {
        return \in_array($permission, self::MATRIX[$this->role()] ?? [], true);
    }

    /** @return list<string> */
    public function permissions(): array
    {
        return self::MATRIX[$this->role()] ?? [];
    }

    public static function roles(): array
    {
        return self::ROLE_LABELS;
    }
}
