<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

final class Money
{
    private const array CURRENCIES = ['USD', 'CAD', 'EUR'];

    private function __construct(
        private readonly int $minor,
        private readonly string $currency,
    ) {
    }

    public static function of(int $minor, string $currency): self
    {
        if (!in_array($currency, self::CURRENCIES, true)) {
            throw new LedgerError('CURRENCY_MISMATCH', 'Money must be USD, CAD, or EUR');
        }
        if ($minor < 0) {
            throw new LedgerError('INVALID_MONEY', 'Money cannot be negative');
        }
        return new self($minor, $currency);
    }

    public static function fromMinorString(string $minor, string $currency): self
    {
        if ($minor !== '0' && preg_match('/^[1-9][0-9]*$/', $minor) !== 1) {
            throw new LedgerError('INVALID_MONEY', 'Money must be a canonical minor-unit string');
        }
        $limit = (string) PHP_INT_MAX;
        if (strlen($minor) > strlen($limit) || (strlen($minor) === strlen($limit) && strcmp($minor, $limit) > 0)) {
            throw new LedgerError('INVALID_MONEY', 'Money is too large');
        }
        return self::of((int) $minor, $currency);
    }

    public static function zero(string $currency): self
    {
        return self::of(0, $currency);
    }

    public function minor(): int
    {
        return $this->minor;
    }

    public function minorString(): string
    {
        return (string) $this->minor;
    }

    public function currency(): string
    {
        return $this->currency;
    }

    public function isZero(): bool
    {
        return $this->minor === 0;
    }

    public function plus(self $other): self
    {
        if ($other->currency !== $this->currency) {
            throw new LedgerError('CURRENCY_MISMATCH', 'Money currencies do not match');
        }
        return new self($this->minor + $other->minor, $this->currency);
    }
}
