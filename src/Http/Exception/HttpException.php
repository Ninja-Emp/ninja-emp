<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Exception;

use RuntimeException;
use Throwable;

/**
 * An exception that maps directly to an HTTP status code. The error-handling
 * middleware turns these into clean responses instead of stack traces.
 */
class HttpException extends RuntimeException
{
    public function __construct(
        private readonly int $statusCode,
        string $message = '',
        ?Throwable $previous = null,
    ) {
        parent::__construct($message !== '' ? $message : self::defaultMessage($statusCode), $statusCode, $previous);
    }

    public function statusCode(): int
    {
        return $this->statusCode;
    }

    private static function defaultMessage(int $status): string
    {
        return match ($status) {
            400 => 'Bad request.',
            401 => 'Authentication required.',
            403 => 'You do not have permission to perform this action.',
            404 => 'Not found.',
            405 => 'Method not allowed.',
            409 => 'Conflict.',
            422 => 'Unprocessable entity.',
            429 => 'Too many requests.',
            default => 'An error occurred.',
        };
    }
}
