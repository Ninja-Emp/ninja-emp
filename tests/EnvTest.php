<?php

declare(strict_types=1);

use NinjaEMP\Support\Env;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Env');

    $keys = [
        'NINJA_TEST_ALPHA',
        'NINJA_TEST_BETA',
        'NINJA_TEST_GAMMA',
        'NINJA_TEST_DELTA',
        'NINJA_TEST_EPSILON',
    ];

    $clear = static function () use ($keys): void {
        foreach ($keys as $k) {
            putenv($k);
            unset($_ENV[$k]);
        }
    };

    $clear();

    $tmp = tempnam(sys_get_temp_dir(), 'ninja_env_');
    $t->assertTrue($tmp !== false, 'temp file created');

    file_put_contents((string) $tmp, implode("\n", [
        '# a comment line',
        '',
        'NINJA_TEST_ALPHA=one',
        'NINJA_TEST_BETA="two"',
        "NINJA_TEST_GAMMA='three'",
        'NINJA_TEST_DELTA=',
        'NINJA_TEST_EPSILON = spaced ',
        'no_equals_sign_here',
        '=novalue',
    ]));

    Env::load((string) $tmp);

    $t->assertSame('one', getenv('NINJA_TEST_ALPHA'), 'plain value loaded');
    $t->assertSame('two', getenv('NINJA_TEST_BETA'), 'double-quoted value stripped');
    $t->assertSame('three', getenv('NINJA_TEST_GAMMA'), 'single-quoted value stripped');
    $t->assertSame('', getenv('NINJA_TEST_DELTA'), 'empty value loaded');
    $t->assertSame('spaced', getenv('NINJA_TEST_EPSILON'), 'key and value trimmed');
    $t->assertSame('one', $_ENV['NINJA_TEST_ALPHA'] ?? null, 'value also exported to $_ENV');

    // A real environment variable always wins over the file.
    putenv('NINJA_TEST_ALPHA=preset');
    Env::load((string) $tmp);
    $t->assertSame('preset', getenv('NINJA_TEST_ALPHA'), 'existing env is not overridden');

    // A missing file is a silent no-op.
    Env::load('/nonexistent/path/to/.env');
    $t->assertTrue(true, 'missing file does not throw');

    // An unreadable file is a silent no-op (directory, not a file).
    Env::load(sys_get_temp_dir());
    $t->assertTrue(true, 'directory path does not throw');

    $clear();
    @unlink((string) $tmp);
};
