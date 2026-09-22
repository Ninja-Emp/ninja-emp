<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Exception;

use Throwable;

/**
 * 404 — the request host/slug did not resolve to an active tenant.
 */
final class TenantNotResolvedException extends HttpException
{
    public function __construct(string $message = 'Unknown or inactive tenant.', ?Throwable $previous = null)
    {
        parent::__construct(404, $message, $previous);
    }
}
