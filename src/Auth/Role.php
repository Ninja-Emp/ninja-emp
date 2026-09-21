<?php

declare(strict_types=1);

namespace NinjaEMP\Auth;

use InvalidArgumentException;

/**
 * Roles and their permission matrix (server-side authority).
 *
 * The UI gates routes for a good experience; this is the enforcement point. The
 * matrix mirrors the tenant UI's mock Auth so the two never drift.
 */
final class Role
{
    public const OWNER = 'owner';
    public const MANAGER = 'manager';
    public const ACCOUNTANT = 'accountant';
    public const CASHIER = 'cashier';

    /** @var array<string, list<string>> */
    private const MATRIX = [
        self::OWNER => [
            'dashboard.view', 'pos.use', 'booths.manage', 'vendors.manage',
            'inventory.manage', 'reports.view', 'settings.manage', 'accounting.view',
        ],
        self::MANAGER => [
            'dashboard.view', 'pos.use', 'booths.manage', 'vendors.manage',
            'inventory.manage', 'reports.view',
        ],
        self::ACCOUNTANT => [
            'dashboard.view', 'vendors.manage', 'reports.view', 'accounting.view',
        ],
        self::CASHIER => [
            'dashboard.view', 'pos.use',
        ],
    ];

    /** @var array<string, string> */
    private const LABELS = [
        self::OWNER => 'Owner',
        self::MANAGER => 'Manager',
        self::ACCOUNTANT => 'Accountant',
        self::CASHIER => 'Cashier',
    ];

    private function __construct(private readonly string $code)
    {
        if (!isset(self::MATRIX[$code])) {
            throw new InvalidArgumentException(sprintf('Unknown role: "%s".', $code));
        }
    }

    public static function of(string $code): self
    {
        return new self($code);
    }

    public static function isValid(string $code): bool
    {
        return isset(self::MATRIX[$code]);
    }

    public function code(): string
    {
        return $this->code;
    }

    public function label(): string
    {
        return self::LABELS[$this->code];
    }

    public function can(string $permission): bool
    {
        return in_array($permission, self::MATRIX[$this->code], true);
    }

    /** @return list<string> */
    public function permissions(): array
    {
        return self::MATRIX[$this->code];
    }

    /** @return array<string, string> code => label */
    public static function all(): array
    {
        return self::LABELS;
    }
}
