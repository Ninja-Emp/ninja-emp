<?php

declare(strict_types=1);

namespace NinjaEMP\Money;

use InvalidArgumentException;
use Stringable;

/**
 * ISO-4217 alpha-3 currency code.
 *
 * Mirrors the database domain kernel.currency_code: char(3), uppercase, ^[A-Z]{3}$.
 * Immutable value object. Never constructed from user input without validation.
 */
final class Currency implements Stringable
{
    /** @var array<string, string> code => display name (the currencies we ship with) */
    private const KNOWN = [
        'USD' => 'US Dollar',
        'EUR' => 'Euro',
        'GBP' => 'Pound Sterling',
        'CAD' => 'Canadian Dollar',
        'AUD' => 'Australian Dollar',
        'NZD' => 'New Zealand Dollar',
        'JPY' => 'Japanese Yen',
        'CHF' => 'Swiss Franc',
        'MXN' => 'Mexican Peso',
        'SEK' => 'Swedish Krona',
        'NOK' => 'Norwegian Krone',
        'DKK' => 'Danish Krone',
    ];

    private function __construct(private readonly string $code)
    {
    }

    /**
     * Build from a 3-letter code. Case-insensitive; normalised to uppercase.
     *
     * @throws InvalidArgumentException when the code is not a valid ISO-4217 alpha-3.
     */
    public static function of(string $code): self
    {
        $normalised = strtoupper(trim($code));

        if (preg_match('/^[A-Z]{3}$/', $normalised) !== 1) {
            throw new InvalidArgumentException(\sprintf('Invalid ISO-4217 currency code: "%s".', $code));
        }

        return new self($normalised);
    }

    /** The functional/base currency of the platform (USD per HANDOFF.md §2). */
    public static function usd(): self
    {
        return new self('USD');
    }

    /** True when this code is one we ship display names for. */
    public function isKnown(): bool
    {
        return isset(self::KNOWN[$this->code]);
    }

    public function code(): string
    {
        return $this->code;
    }

    public function name(): string
    {
        return self::KNOWN[$this->code] ?? $this->code;
    }

    public function equals(self $other): bool
    {
        return $this->code === $other->code;
    }

    public function __toString(): string
    {
        return $this->code;
    }
}
