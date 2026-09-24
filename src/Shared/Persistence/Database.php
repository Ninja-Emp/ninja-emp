<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use PDO;
use RuntimeException;

final class Database
{
    public static function connectFromEnv(): PDO
    {
        $url = getenv('EMP_POS_DATABASE_URL');
        if (!is_string($url) || $url === '') {
            $url = 'postgres://emp:emp@127.0.0.1:5433/emp_pos';
        }
        return self::connect($url);
    }

    public static function connect(string $url): PDO
    {
        $parts = parse_url($url);
        if ($parts === false || !isset($parts['host'], $parts['path'])) {
            throw new RuntimeException('Database URL is not a postgres URL');
        }
        $scheme = $parts['scheme'] ?? '';
        if ($scheme !== 'postgres' && $scheme !== 'postgresql') {
            throw new RuntimeException('Database URL is not a postgres URL');
        }
        $user = $parts['user'] ?? '';
        $password = $parts['pass'] ?? '';
        $port = isset($parts['port']) ? (int) $parts['port'] : 5432;
        $name = ltrim((string) $parts['path'], '/');
        if ($user === '' || $name === '' || $port < 1) {
            throw new RuntimeException('Database URL is missing user, port, or database');
        }
        $dsn = sprintf('pgsql:host=%s;port=%d;dbname=%s', $parts['host'], $port, $name);
        return new PDO($dsn, $user, $password, [
            PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
            PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
        ]);
    }
}
