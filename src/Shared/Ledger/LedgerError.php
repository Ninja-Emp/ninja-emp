<?php

declare(strict_types=1);

namespace EmpPos\Shared\Ledger;

use RuntimeException;

final class LedgerError extends RuntimeException
{
    public function __construct(
        private readonly string $errorCode,
        string $message,
    ) {
        parent::__construct($message);
    }

    public function errorCode(): string
    {
        return $this->errorCode;
    }
}
