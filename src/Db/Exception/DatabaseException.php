<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Exception;

use RuntimeException;
use Throwable;

/**
 * Base class for every typed database failure surfaced by the DBAL.
 * Carries the SQLSTATE so callers can branch without parsing messages.
 */
class DatabaseException extends RuntimeException
{
    public function __construct(
        string $message,
        private readonly ?string $sqlState = null,
        ?Throwable $previous = null,
    ) {
        parent::__construct($message, 0, $previous);
    }

    public function sqlState(): ?string
    {
        return $this->sqlState;
    }
}
