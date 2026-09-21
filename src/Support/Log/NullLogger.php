<?php

declare(strict_types=1);

namespace NinjaEMP\Support\Log;

use Psr\Log\AbstractLogger;

/**
 * A no-op PSR-3 logger. The DBAL depends on the PSR-3 interface, not on Monolog,
 * so the layer stays testable and dependency-free. Swap in Monolog in production.
 */
final class NullLogger extends AbstractLogger
{
    public function log($level, \Stringable|string $message, array $context = []): void
    {
        // Intentionally does nothing.
    }
}
