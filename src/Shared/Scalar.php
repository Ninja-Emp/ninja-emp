<?php

declare(strict_types=1);

namespace EmpPos\Shared;

final class Scalar
{
    /**
     * @param array<string, mixed> $row
     */
    public static function text(array $row, string $key): string
    {
        return self::string($row[$key] ?? null, $key);
    }

    /**
     * @param array<string, mixed> $row
     */
    public static function nullableText(array $row, string $key): ?string
    {
        $value = $row[$key] ?? null;
        if ($value === null) {
            return null;
        }
        return self::string($value, $key);
    }

    /**
     * @return array<string, mixed>
     */
    public static function row(mixed $value): array
    {
        if (!is_array($value)) {
            throw new \RuntimeException('Expected a row');
        }
        $row = [];
        foreach ($value as $key => $cell) {
            if (!is_string($key)) {
                throw new \RuntimeException('Expected a row');
            }
            $row[$key] = $cell;
        }
        return $row;
    }

    /**
     * @param array<string, mixed> $row
     */
    public static function int(array $row, string $key): int
    {
        $value = $row[$key] ?? null;
        if (is_int($value)) {
            return $value;
        }
        if (is_string($value) && preg_match('/^-?[0-9]+$/', $value) === 1) {
            return (int) $value;
        }
        throw new \RuntimeException($key . ' is not an integer');
    }

    public static function string(mixed $value, string $name): string
    {
        if (is_string($value) || is_int($value)) {
            return (string) $value;
        }
        throw new \RuntimeException($name . ' is not text');
    }
}
