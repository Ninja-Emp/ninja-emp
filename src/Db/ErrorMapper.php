<?php

declare(strict_types=1);

namespace NinjaEMP\Db;

use NinjaEMP\Db\Exception\AppendOnlyViolationException;
use NinjaEMP\Db\Exception\ConflictException;
use NinjaEMP\Db\Exception\ConstraintViolationException;
use NinjaEMP\Db\Exception\DatabaseException;
use NinjaEMP\Db\Exception\LedgerBalanceException;
use NinjaEMP\Db\Exception\ReferenceException;
use NinjaEMP\Db\Exception\RetryableException;
use NinjaEMP\Db\Sql\Value;
use PDOException;

/**
 * Maps SQLSTATE codes to typed exceptions (ADR-0025 §8). The DBAL never swallows
 * errors; every failure is typed so callers can branch without parsing messages.
 */
final class ErrorMapper
{
    public function map(PDOException $e): DatabaseException
    {
        $state = $e->getCode() !== '' ? Value::str($e->getCode()) : null;
        $message = $e->getMessage();

        return match ($state) {
            '23514' => $this->constraintViolation($message, $state, $e),
            '23503' => new ReferenceException($message, $state, $e),
            '23505' => new ConflictException($message, $state, $e),
            '55000' => new AppendOnlyViolationException($message, $state, $e),
            '40001' => new RetryableException($message, $state, $e),
            default => new DatabaseException($message, $state, $e),
        };
    }

    /**
     * A check_violation that mentions the ledger balance trigger is surfaced as a
     * specialised LedgerBalanceException so the ledger can catch it precisely.
     */
    private function constraintViolation(string $message, string $state, PDOException $e): ConstraintViolationException
    {
        if (stripos($message, 'balance') !== false || stripos($message, 'assert_entry_balanced') !== false) {
            return new LedgerBalanceException($message, $state, $e);
        }

        return new ConstraintViolationException($message, $state, $e);
    }
}
