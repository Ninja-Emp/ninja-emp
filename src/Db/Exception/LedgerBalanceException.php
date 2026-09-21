<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Exception;

/**
 * Raised when the ledger's deferred balance trigger fires at COMMIT
 * (Σ debits ≠ Σ credits). A specialised ConstraintViolationException so callers
 * can catch either the general or the specific case.
 */
final class LedgerBalanceException extends ConstraintViolationException
{
}
