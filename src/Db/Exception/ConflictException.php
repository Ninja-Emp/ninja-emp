<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Exception;

/**
 * SQLSTATE 23505 — unique_violation. Includes idempotency-key collisions.
 */
final class ConflictException extends DatabaseException
{
}
