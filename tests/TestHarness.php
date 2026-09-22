<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use Throwable;

/**
 * A tiny, dependency-free assertion harness. No PHPUnit (zero deps per HANDOFF.md).
 * Each test file returns a closure that receives the harness and registers cases.
 */
final class TestHarness
{
    private int $passed = 0;
    private int $failed = 0;

    /** @var list<string> */
    private array $failures = [];

    private string $suite = '';

    public function suite(string $name): void
    {
        $this->suite = $name;
    }

    public function assertSame(mixed $expected, mixed $actual, string $message): void
    {
        if ($expected === $actual) {
            $this->passed++;

            return;
        }

        $this->fail($message, \sprintf('expected %s, got %s', $this->dump($expected), $this->dump($actual)));
    }

    public function assertTrue(bool $condition, string $message): void
    {
        $this->assertSame(true, $condition, $message);
    }

    public function assertFalse(bool $condition, string $message): void
    {
        $this->assertSame(false, $condition, $message);
    }

    public function assertThrows(string $exceptionClass, callable $fn, string $message): void
    {
        try {
            $fn();
        } catch (Throwable $e) {
            if ($e instanceof $exceptionClass) {
                $this->passed++;

                return;
            }

            $this->fail($message, \sprintf('expected %s, got %s', $exceptionClass, $e::class));

            return;
        }

        $this->fail($message, \sprintf('expected %s, nothing thrown', $exceptionClass));
    }

    private function fail(string $message, string $detail): void
    {
        $this->failed++;
        $this->failures[] = \sprintf('[%s] %s — %s', $this->suite, $message, $detail);
    }

    private function dump(mixed $value): string
    {
        return match (true) {
            \is_string($value) => '"' . $value . '"',
            \is_bool($value) => $value ? 'true' : 'false',
            \is_null($value) => 'null',
            \is_array($value) => json_encode($value),
            default => (string) $value,
        };
    }

    public function report(): int
    {
        echo "\n";

        foreach ($this->failures as $failure) {
            echo "  ✗ {$failure}\n";
        }

        $total = $this->passed + $this->failed;
        echo \sprintf("\n  %d assertions, %d passed, %d failed\n", $total, $this->passed, $this->failed);

        return $this->failed === 0 ? 0 : 1;
    }
}
