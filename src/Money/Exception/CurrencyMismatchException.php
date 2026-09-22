<?php

declare(strict_types=1);

namespace NinjaEMP\Money\Exception;

use NinjaEMP\Money\Currency;
use RuntimeException;

/**
 * Thrown when arithmetic is attempted across two different currencies.
 * Cross-currency work must go through an explicit FX conversion first.
 */
final class CurrencyMismatchException extends RuntimeException
{
    public function __construct(Currency $left, Currency $right)
    {
        parent::__construct(\sprintf(
            'Cannot combine amounts in different currencies: %s vs %s.',
            $left->code(),
            $right->code(),
        ));
    }
}
