<?php

declare(strict_types=1);

namespace NinjaEMP\Db\Exception;

/**
 * SQLSTATE 55000 — object_not_in_prerequisite_state. Raised when something tries
 * to UPDATE/DELETE an append-only table (journal_entry, journal_line, …).
 */
final class AppendOnlyViolationException extends DatabaseException
{
}
