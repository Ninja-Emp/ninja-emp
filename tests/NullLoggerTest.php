<?php

declare(strict_types=1);

use NinjaEMP\Support\Log\NullLogger;
use NinjaEMP\Tests\TestHarness;
use Psr\Log\LoggerInterface;

return static function (TestHarness $t): void {
    $t->suite('NullLogger');

    $logger = new NullLogger();

    $t->assertTrue($logger instanceof LoggerInterface, 'implements PSR-3 LoggerInterface');

    // Every call is a no-op and must not throw.
    $logger->log('info', 'hello', ['a' => 1]);
    $logger->info('hello');
    $logger->error('boom');
    $logger->debug('trace');

    $t->assertTrue(true, 'logging is a silent no-op');
};
