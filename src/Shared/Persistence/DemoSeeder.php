<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use PDO;

final class DemoSeeder
{
    public const string SLUG = 'demo';

    public const string SCHEMA = 'tenant_018f0000_0000_7000_8000_000000000001';

    public function __construct(
        private PDO $pdo,
        private Migrator $migrator,
        private DemoBooks $books,
        private string $root,
    ) {
    }

    public function reseed(): void
    {
        $this->migrator->migrateShared();
        $this->pdo->beginTransaction();
        try {
            $this->wipeIfPresent();
            $this->pdo->exec('CREATE SCHEMA ' . $this->quoted());
            $this->migrator->applyTenant(self::SCHEMA);
            $this->pdo->exec('SET search_path TO ' . $this->quoted() . ', public');
            $this->pdo->exec($this->seedSql());
            $this->assertSchemaName();
            $this->pdo->exec('SET CONSTRAINTS ALL IMMEDIATE');
            $this->books->assertSaturday($this->pdo);
            $this->pdo->commit();
        } catch (\Throwable $error) {
            if ($this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }
            throw $error;
        }
    }

    private function wipeIfPresent(): void
    {
        $select = $this->pdo->prepare(
            'SELECT status, schema_name FROM public.tenants WHERE slug = ? FOR UPDATE',
        );
        $select->execute([self::SLUG]);
        $row = $select->fetch();
        $schemaExists = $this->schemaExists();
        if ($row === false && $schemaExists) {
            throw new WipeRefused('Demo schema exists without a demo tenant row');
        }
        if ($row === false) {
            return;
        }
        $status = (string) $row['status'];
        $schema = (string) $row['schema_name'];
        if ($status !== 'demo') {
            throw new WipeRefused('Wipe refused: store is live');
        }
        if ($schema !== self::SCHEMA) {
            throw new WipeRefused('Wipe refused: demo slug is not the named demo schema');
        }
        if ($schemaExists) {
            $this->pdo->exec('DROP SCHEMA ' . $this->quoted() . ' CASCADE');
        }
        $delete = $this->pdo->prepare(
            'DELETE FROM public.schema_migrations WHERE migration_key LIKE ?',
        );
        $delete->execute(['tenant:' . self::SCHEMA . ':%']);
    }

    public function assertLiveWipeRefused(): void
    {
        if ($this->pdo->inTransaction()) {
            throw new \RuntimeException('Live wipe proof must own its transaction');
        }
        $this->pdo->beginTransaction();
        try {
            $update = $this->pdo->prepare('UPDATE public.tenants SET status = ? WHERE slug = ?');
            $update->execute(['live', self::SLUG]);
            if ($update->rowCount() !== 1) {
                throw new \RuntimeException('Demo tenant row was not updated');
            }
            $refused = false;
            try {
                $this->wipeIfPresent();
            } catch (WipeRefused) {
                $refused = true;
            }
            if (!$refused) {
                throw new \RuntimeException('Live store wipe was allowed');
            }
            $this->pdo->rollBack();
        } catch (\Throwable $error) {
            if ($this->pdo->inTransaction()) {
                $this->pdo->rollBack();
            }
            throw $error;
        }
    }

    private function schemaExists(): bool
    {
        $select = $this->pdo->prepare('SELECT 1 FROM pg_namespace WHERE nspname = ?');
        $select->execute([self::SCHEMA]);
        return $select->fetchColumn() !== false;
    }

    private function assertSchemaName(): void
    {
        $select = $this->pdo->prepare('SELECT schema_name FROM public.tenants WHERE slug = ?');
        $select->execute([self::SLUG]);
        $schema = $select->fetchColumn();
        if ($schema !== self::SCHEMA) {
            throw new \RuntimeException('Demo tenant schema name does not match the fixed id');
        }
    }

    private function seedSql(): string
    {
        $path = $this->root . '/seed/demo.sql';
        if (!is_file($path)) {
            throw new \RuntimeException('Demo seed is missing');
        }
        $sql = file_get_contents($path);
        if ($sql === false || trim($sql) === '') {
            throw new \RuntimeException('Demo seed is empty');
        }
        return $sql;
    }

    private function quoted(): string
    {
        return '"' . self::SCHEMA . '"';
    }
}
