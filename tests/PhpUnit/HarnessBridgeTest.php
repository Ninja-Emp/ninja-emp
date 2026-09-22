<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\PhpUnit;

use NinjaEMP\Tests\TestHarness;
use PHPUnit\Framework\Attributes\DataProvider;
use PHPUnit\Framework\TestCase;

/**
 * Bridges the zero-dependency assertion harness (tests/*Test.php) into PHPUnit.
 *
 * The project's unit tests are plain closures registered against a tiny
 * TestHarness (no PHPUnit dependency at runtime). Mutation testing (Infection)
 * and the CI gate, however, need a PHPUnit entry point. This class discovers
 * every tests/*Test.php file, runs its closure against a fresh harness, and
 * asserts the suite reported zero failures.
 *
 * One PHPUnit test case per suite file keeps per-file coverage granularity,
 * which Infection uses to map mutants to the tests that cover them.
 */
final class HarnessBridgeTest extends TestCase
{
    /**
     * @return iterable<string, array{string}>
     */
    public static function suiteFiles(): iterable
    {
        $files = glob(__DIR__ . '/../*Test.php') ?: [];
        sort($files);

        foreach ($files as $file) {
            yield basename($file) => [$file];
        }
    }

    #[DataProvider('suiteFiles')]
    public function testSuitePasses(string $file): void
    {
        $harness = new TestHarness();

        /** @var callable(TestHarness): void $register */
        $register = require $file;
        $register($harness);

        ob_start();
        $exitCode = $harness->report();
        $output = (string) ob_get_clean();

        self::assertSame(0, $exitCode, $output);
    }
}
