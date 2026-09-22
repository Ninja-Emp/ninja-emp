<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Exception;

use Throwable;

/**
 * 401 — no authenticated principal on the request.
 */
final class UnauthorizedException extends HttpException
{
    public function __construct(string $message = 'Authentication required.', ?Throwable $previous = null)
    {
        parent::__construct(401, $message, $previous);
    }
}
