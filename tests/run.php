<?php

declare(strict_types=1);

/**
 * Zero-dependency test runner. Discovers tests/*Test.php, runs each, reports.
 * Usage: php tests/run.php
 */
require __DIR__ . '/../src/autoload.php';
require __DIR__ . '/TestHarness.php';

use NinjaEMP\Tests\TestHarness;

$harness = new TestHarness();

$files = glob(__DIR__ . '/*Test.php') ?: [];
sort($files);

foreach ($files as $file) {
    /** @var callable(TestHarness): void $register */
    $register = require $file;
    $register($harness);
}

exit($harness->report());
