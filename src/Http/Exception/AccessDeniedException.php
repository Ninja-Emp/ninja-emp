<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Exception;

use Throwable;

/**
 * 403 — the principal is authenticated but lacks the required permission.
 */
final class AccessDeniedException extends HttpException
{
    public function __construct(
        private readonly ?string $permission = null,
        string $message = '',
        ?Throwable $previous = null,
    ) {
        parent::__construct(403, $message, $previous);
    }

    public function permission(): ?string
    {
        return $this->permission;
    }
}
