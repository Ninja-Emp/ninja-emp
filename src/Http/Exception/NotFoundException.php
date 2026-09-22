<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Exception;

use Throwable;

/**
 * 404 — the requested resource or route does not exist.
 */
final class NotFoundException extends HttpException
{
    public function __construct(string $message = 'Not found.', ?Throwable $previous = null)
    {
        parent::__construct(404, $message, $previous);
    }
}
