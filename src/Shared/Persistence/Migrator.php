<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use PDO;

final class Migrator
{
    public function __construct(
        private PDO $pdo,
        private string $root,
    ) {
    }

    public function migrateShared(): void
    {
        $path = $this->root . '/migrations/shared/001_public.sql';
        $sql = $this->read($path);
        $this->pdo->beginTransaction();
        try {
            $this->apply('shared:001_public.sql', $sql);
            $this->pdo->commit();
        } catch (\Throwable $error) {
            $this->rollBack();
            throw $error;
        }
    }

    public function migrateTenant(string $schema): void
    {
        $this->pdo->beginTransaction();
        try {
            $this->applyTenant($schema);
            $this->pdo->commit();
        } catch (\Throwable $error) {
            $this->rollBack();
            throw $error;
        }
    }

    public function applyTenant(string $schema): void
    {
        $quoted = $this->quoteSchema($schema);
        $this->pdo->exec('CREATE SCHEMA IF NOT EXISTS ' . $quoted);
        $this->pdo->exec('SET search_path TO ' . $quoted . ', public');
        $sql = $this->read($this->root . '/migrations/tenant/001_store.sql');
        $this->apply('tenant:' . $schema . ':001_store.sql', $sql);
    }

    private function apply(string $key, string $sql): void
    {
        $checksum = hash('sha256', $sql);
        $existing = $this->checksum($key);
        if ($existing !== null) {
            if (!hash_equals($existing, $checksum)) {
                throw new MigrationDrift('Migration ' . $key . ' does not match the applied checksum');
            }
            return;
        }
        $this->pdo->exec($sql);
        $insert = $this->pdo->prepare(
            'INSERT INTO public.schema_migrations (migration_key, checksum) VALUES (?, ?)',
        );
        $insert->execute([$key, $checksum]);
    }

    private function checksum(string $key): ?string
    {
        $ready = $this->pdo->query("SELECT to_regclass('public.schema_migrations')")->fetchColumn();
        if ($ready === false || $ready === null) {
            return null;
        }
        $select = $this->pdo->prepare('SELECT checksum FROM public.schema_migrations WHERE migration_key = ?');
        $select->execute([$key]);
        $value = $select->fetchColumn();
        if ($value === false) {
            return null;
        }
        return (string) $value;
    }

    private function read(string $path): string
    {
        if (!is_file($path)) {
            throw new \RuntimeException('Migration file is missing');
        }
        $sql = file_get_contents($path);
        if ($sql === false || trim($sql) === '') {
            throw new \RuntimeException('Migration file is empty');
        }
        return $sql;
    }

    private function quoteSchema(string $schema): string
    {
        if (preg_match('/^[a-z_][a-z0-9_]*$/', $schema) !== 1) {
            throw new \RuntimeException('Schema name is not safe to create');
        }
        return '"' . $schema . '"';
    }

    private function rollBack(): void
    {
        if ($this->pdo->inTransaction()) {
            $this->pdo->rollBack();
        }
    }
}
