<?php

declare(strict_types=1);

namespace NinjaEMP\Support;

/**
 * A tiny, dependency-free `.env` loader.
 *
 * Reads KEY=VALUE lines (ignoring blanks and `#` comments), strips surrounding
 * quotes, and exports each key via putenv()/$_ENV — but only when the key is not
 * already set, so real environment variables always win over the file.
 *
 * This is deliberately minimal: no interpolation, no multiline values. It exists
 * so `cp .env.example .env` is all a developer needs to configure the app.
 */
final class Env
{
    public static function load(string $file): void
    {
        if (!is_file($file) || !is_readable($file)) {
            return;
        }

        $lines = file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);

        if ($lines === false) {
            return;
        }

        foreach ($lines as $line) {
            $pair = self::parseLine($line);

            if ($pair === null) {
                continue;
            }

            [$key, $value] = $pair;

            if (getenv($key) !== false) {
                continue;
            }

            putenv($key . '=' . $value);
            $_ENV[$key] = $value;
        }
    }

    /**
     * Parse a single `KEY=VALUE` line.
     *
     * @return array{0: string, 1: string}|null null for blanks, comments, and
     *                                          lines without a key or `=`.
     */
    private static function parseLine(string $line): ?array
    {
        $line = trim($line);

        if ($line === '' || str_starts_with($line, '#') || !str_contains($line, '=')) {
            return null;
        }

        [$key, $value] = explode('=', $line, 2);
        $key = trim($key);

        if ($key === '') {
            return null;
        }

        return [$key, trim(trim($value), "\"'")];
    }
}
