<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use EmpPos\Shared\Scalar;
use PDO;
use PDOStatement;
use RuntimeException;

final class Sql
{
    public static function statement(PDO $pdo, string $sql): PDOStatement
    {
        $statement = $pdo->query($sql);
        if ($statement === false) {
            throw new RuntimeException('Query failed');
        }
        return $statement;
    }

    public static function column(PDO $pdo, string $sql): mixed
    {
        return self::statement($pdo, $sql)->fetchColumn();
    }

    /**
     * @return list<array<string, mixed>>
     */
    public static function rows(PDO $pdo, string $sql): array
    {
        $out = [];
        foreach (self::statement($pdo, $sql)->fetchAll() as $row) {
            $out[] = Scalar::row($row);
        }
        return $out;
    }
}
