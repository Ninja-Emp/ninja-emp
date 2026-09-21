<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Exception;

/**
 * Raised when tenant-scoped work is attempted outside a transaction. SET LOCAL
 * requires a transaction, so a bare select()/execute() is a programming error.
 */
final class TransactionRequiredException extends DatabaseException
{
}
