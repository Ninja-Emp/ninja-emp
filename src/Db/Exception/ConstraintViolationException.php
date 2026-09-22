<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Exception;

/**
 * SQLSTATE 23514 — check_violation. Includes unbalanced journal entries and
 * period-lock violations.
 */
class ConstraintViolationException extends DatabaseException
{
}
