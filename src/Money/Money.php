<?php

declare(strict_types=1);

namespace NinjaEMP\Money;

use InvalidArgumentException;
use NinjaEMP\Db\Sql\Value;
use NinjaEMP\Money\Exception\CurrencyMismatchException;
use Stringable;

/**
 * Exact monetary amount, string-backed, scale 4 (ADR-0002 / ADR-0011).
 *
 * The database stores money as NUMERIC(19,4). PDO hands that back as a *string*.
 * This object preserves that exactness end-to-end: the amount is held as a
 * canonical decimal string and every operation goes through bcmath. It is
 * impossible to accidentally introduce a float.
 *
 * Scale 4 is the rounding boundary. Operations that would exceed scale 4 must be
 * routed through the largest-remainder allocator (ADR-0009) by the caller; this
 * class refuses to silently round.
 */
final class Money implements Stringable
{
    public const SCALE = 4;

    /**
     * @param numeric-string $amount canonical decimal string, exactly SCALE places
     */
    private function __construct(
        private readonly string $amount,
        private readonly Currency $currency,
    ) {
    }

    /**
     * Build from a decimal string (or int). Never accepts a float.
     *
     * @throws InvalidArgumentException on malformed input or float input.
     */
    public static function of(string|int $amount, Currency $currency): self
    {
        if (\is_int($amount)) {
            $amount = Value::str($amount);
        }

        $amount = trim($amount);

        if ($amount === '' || preg_match('/^-?\d+(\.\d+)?$/', $amount) !== 1) {
            throw new InvalidArgumentException(\sprintf('Malformed money amount: "%s".', $amount));
        }

        return new self(self::normalise($amount), $currency);
    }

    /**
     * Build from a raw PDO value. PDO returns NUMERIC as string; we accept string
     * or int and reject float loudly (a float here means someone bypassed the DBAL).
     */
    public static function fromDatabase(string|int|float $value, Currency $currency): self
    {
        if (\is_float($value)) {
            throw new InvalidArgumentException(
                'Refusing to build Money from a float — money must stay exact (ADR-0002).',
            );
        }

        return self::of($value, $currency);
    }

    public static function zero(Currency $currency): self
    {
        return new self('0.0000', $currency);
    }

    /** @return numeric-string */
    public function amount(): string
    {
        return $this->amount;
    }

    public function currency(): Currency
    {
        return $this->currency;
    }

    public function isZero(): bool
    {
        return bccomp($this->amount, '0', self::SCALE) === 0;
    }

    public function isNegative(): bool
    {
        return bccomp($this->amount, '0', self::SCALE) < 0;
    }

    public function isPositive(): bool
    {
        return bccomp($this->amount, '0', self::SCALE) > 0;
    }

    public function negated(): self
    {
        return new self(bcmul($this->amount, '-1', self::SCALE), $this->currency);
    }

    public function abs(): self
    {
        return $this->isNegative() ? $this->negated() : $this;
    }

    public function plus(self $other): self
    {
        $this->assertSameCurrency($other);

        return new self(bcadd($this->amount, $other->amount, self::SCALE), $this->currency);
    }

    public function minus(self $other): self
    {
        $this->assertSameCurrency($other);

        return new self(bcsub($this->amount, $other->amount, self::SCALE), $this->currency);
    }

    /**
     * Multiply by an exact decimal factor (e.g. a tax rate or quantity).
     * The factor is a string to keep the whole path float-free.
     */
    public function times(string|int $factor): self
    {
        $factor = \is_int($factor) ? Value::str($factor) : trim($factor);

        if ($factor === '' || preg_match('/^-?\d+(\.\d+)?$/', $factor) !== 1) {
            throw new InvalidArgumentException(\sprintf('Malformed multiplier: "%s".', $factor));
        }

        return new self(bcmul($this->amount, Value::num($factor), self::SCALE), $this->currency);
    }

    /**
     * Divide by an exact decimal divisor. Refuses division by zero.
     */
    public function dividedBy(string|int $divisor): self
    {
        $divisor = \is_int($divisor) ? Value::str($divisor) : trim($divisor);

        if ($divisor === '' || preg_match('/^-?\d+(\.\d+)?$/', $divisor) !== 1) {
            throw new InvalidArgumentException(\sprintf('Malformed divisor: "%s".', $divisor));
        }

        $divisor = Value::num($divisor);

        if (bccomp($divisor, '0', self::SCALE) === 0) {
            throw new InvalidArgumentException('Division by zero.');
        }

        return new self(bcdiv($this->amount, $divisor, self::SCALE), $this->currency);
    }

    public function compareTo(self $other): int
    {
        $this->assertSameCurrency($other);

        return bccomp($this->amount, $other->amount, self::SCALE);
    }

    public function equals(self $other): bool
    {
        return $this->currency->equals($other->currency)
            && bccomp($this->amount, $other->amount, self::SCALE) === 0;
    }

    public function greaterThan(self $other): bool
    {
        return $this->compareTo($other) > 0;
    }

    public function lessThan(self $other): bool
    {
        return $this->compareTo($other) < 0;
    }

    /**
     * Render for display with a fixed number of minor-unit decimals.
     * Default 2 (cents). This is presentation only — never feed it back into maths.
     */
    public function format(int $decimals = 2): string
    {
        return number_format(Value::float($this->amount), $decimals, '.', ',');
    }

    /** The exact decimal string, suitable for binding back to the database. */
    public function __toString(): string
    {
        return $this->amount;
    }

    private function assertSameCurrency(self $other): void
    {
        if (!$this->currency->equals($other->currency)) {
            throw new CurrencyMismatchException($this->currency, $other->currency);
        }
    }

    /**
     * Canonicalise to exactly SCALE decimal places, half-up, without floats.
     *
     * @return numeric-string
     */
    private static function normalise(string $amount): string
    {
        $negative = str_starts_with($amount, '-');
        $unsigned = ltrim($amount, '-');

        [$whole, $fraction] = array_pad(explode('.', $unsigned, 2), 2, '');

        if (\strlen($fraction) > self::SCALE) {
            // Round half-up at the boundary using integer string maths.
            $keep = substr($fraction, 0, self::SCALE);
            $next = $fraction[self::SCALE] ?? '0';
            $scaled = Value::num($whole . $keep);

            if ($next >= '5') {
                $scaled = bcadd($scaled, '1', 0);
            }

            $wholePart = substr($scaled, 0, max(0, \strlen($scaled) - self::SCALE));
            $whole = $wholePart === '' ? '0' : $wholePart;
            $fraction = str_pad(substr($scaled, -self::SCALE), self::SCALE, '0', STR_PAD_LEFT);
        } else {
            $fraction = str_pad($fraction, self::SCALE, '0', STR_PAD_RIGHT);
        }

        $whole = ltrim($whole, '0');

        if ($whole === '') {
            $whole = '0';
        }

        $result = Value::num($whole . '.' . $fraction);

        if ($negative && bccomp($result, '0', self::SCALE) !== 0) {
            return Value::num('-' . $result);
        }

        return $result;
    }
}
