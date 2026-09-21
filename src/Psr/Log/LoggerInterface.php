<?php

declare(strict_types=1);

namespace Psr\Log;

/**
 * Minimal PSR-3 logger interface (vendored, no Composer).
 * Describes a logger instance per the PSR-3 specification.
 */
interface LoggerInterface
{
    public function emergency(\Stringable|string $message, array $context = []): void;

    public function alert(\Stringable|string $message, array $context = []): void;

    public function critical(\Stringable|string $message, array $context = []): void;

    public function error(\Stringable|string $message, array $context = []): void;

    public function warning(\Stringable|string $message, array $context = []): void;

    public function notice(\Stringable|string $message, array $context = []): void;

    public function info(\Stringable|string $message, array $context = []): void;

    public function debug(\Stringable|string $message, array $context = []): void;

    public function log($level, \Stringable|string $message, array $context = []): void;
}
