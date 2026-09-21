<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Exception;

/**
 * SQLSTATE 40001 — serialization_failure. The caller may safely retry the
 * whole unit of work.
 */
final class RetryableException extends DatabaseException
{
}
