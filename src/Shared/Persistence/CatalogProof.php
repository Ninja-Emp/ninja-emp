<?php

declare(strict_types=1);

namespace EmpPos\Shared\Persistence;

use PDO;
use RuntimeException;

final class CatalogProof
{
    private const string PROBE = 'catalog_probe';

    private const string EMPTY_CHAIN = 'nest_tenant';

    /** @var list<string> */
    private const array INTAKE = [
        'intake_show_category',
        'intake_show_brand',
        'intake_show_color',
        'intake_show_size',
        'intake_show_notes',
    ];

    public function __construct(
        private Migrator $migrator,
    ) {
    }

    public function prove(PDO $pos, PDO $nest, PDO $reference): void
    {
        $this->readOnly($nest);
        $this->readOnly($reference);
        try {
            $publicNest = $this->snapshot($nest, 'public');
            $tenant = $this->nestTenant($nest);
            $storeNest = $this->snapshot($nest, $tenant);
            $emptyChain = $this->captureReference($reference, self::EMPTY_CHAIN);
        } finally {
            $this->endRead($nest);
            $this->endRead($reference);
        }

        $this->assertMatch($this->snapshot($pos, 'public'), $publicNest, 'public');

        if ($this->schemaExists($pos, self::PROBE)) {
            throw new RuntimeException('catalog_probe already exists');
        }

        $pos->beginTransaction();
        try {
            $this->migrator->applyTenant(self::PROBE);
            $this->assertMatch($this->snapshot($pos, self::PROBE), $storeNest, 'store');
            $this->assertReference($pos, self::PROBE, $emptyChain);
            $pos->rollBack();
        } catch (\Throwable $error) {
            if ($pos->inTransaction()) {
                $pos->rollBack();
            }
            throw $error;
        }

        if ($this->schemaExists($pos, self::PROBE)) {
            throw new RuntimeException('catalog_probe was not rolled back');
        }
    }

    private function readOnly(PDO $pdo): void
    {
        if ($pdo->inTransaction()) {
            throw new RuntimeException('Catalog proof expected a fresh connection');
        }
        $pdo->beginTransaction();
        $pdo->exec('SET TRANSACTION READ ONLY');
    }

    private function endRead(PDO $pdo): void
    {
        if ($pdo->inTransaction()) {
            $pdo->rollBack();
        }
    }

    private function nestTenant(PDO $nest): string
    {
        $schema = $nest->query(
            "SELECT substring(migration_key FROM '^tenant:(tenant_[a-z0-9_]+):066_intake_defaults_off\\.sql$')
             FROM public.schema_migrations
             WHERE migration_key LIKE '%:066_intake_defaults_off.sql'
             ORDER BY 1
             LIMIT 1",
        )->fetchColumn();
        if (!is_string($schema) || $schema === '') {
            throw new RuntimeException('No Nest tenant is at migration 066');
        }
        $this->ident($schema);
        return $schema;
    }

    /**
     * @return list<string>
     */
    private function snapshot(PDO $pdo, string $schema): array
    {
        $this->ident($schema);
        $lines = [];
        foreach ($this->queries() as $sql) {
            $select = $pdo->prepare($sql);
            $select->execute([$schema]);
            foreach ($select->fetchAll(PDO::FETCH_NUM) as $row) {
                foreach (explode("\n", (string) $row[0]) as $line) {
                    $lines[] = $this->normalize($line, $schema);
                }
            }
        }
        if ($lines === []) {
            throw new RuntimeException('Catalog snapshot is empty');
        }
        return $lines;
    }

    /**
     * Column order is the live ordinal, not attnum, so a dropped column is not a diff.
     * CHECK text from a dump replay spells the same cast differently than the original migration.
     */
    private function normalize(string $line, string $schema): string
    {
        if ($schema !== 'public') {
            $line = str_replace($schema . '.', '', $line);
        }
        $line = str_replace('::character varying::text', '::character varying', $line);
        return str_replace(']::text[]', ']', $line);
    }

    /**
     * @param list<string> $left
     * @param list<string> $right
     */
    private function assertMatch(array $left, array $right, string $label): void
    {
        $limit = min(count($left), count($right));
        for ($index = 0; $index < $limit; $index++) {
            if ($left[$index] !== $right[$index]) {
                throw new RuntimeException(
                    $label . ' catalog differs at line ' . ($index + 1)
                    . "\n" . $left[$index]
                    . "\n" . $right[$index],
                );
            }
        }
        if (count($left) !== count($right)) {
            throw new RuntimeException($label . ' catalog length ' . count($left) . ' vs ' . count($right));
        }
    }

    /**
     * @return array{accounts: list<string>, house: list<string>, locations: list<string>, thresholds: list<string>, settings: array<string, string>}
     */
    private function captureReference(PDO $pdo, string $schema): array
    {
        if (!$this->schemaExists($pdo, $schema)) {
            throw new RuntimeException('Empty Nest chain schema is missing');
        }
        return [
            'accounts' => $this->projection($pdo, $schema, 'SELECT code, name, account_type, normal_balance, is_postable::text, is_control::text, COALESCE(subledger_type, \'\') FROM __SCHEMA__.accounts ORDER BY code'),
            'house' => $this->projection($pdo, $schema, 'SELECT display_name, COALESCE(first_name, \'\'), COALESCE(last_name, \'\'), commission_bps::text, kind, portal_enabled::text FROM __SCHEMA__.parties WHERE kind = \'house\' ORDER BY display_name'),
            'locations' => $this->projection($pdo, $schema, 'SELECT location_name, is_default::text FROM __SCHEMA__.store_locations ORDER BY location_name'),
            'thresholds' => $this->projection($pdo, $schema, 'SELECT form_code, box_code, tax_year::text, amount_minor::text, currency FROM __SCHEMA__.tax_form_thresholds ORDER BY form_code, box_code, tax_year, currency'),
            'settings' => $this->settingsRow($pdo, $schema),
        ];
    }

    /**
     * @param array{accounts: list<string>, house: list<string>, locations: list<string>, thresholds: list<string>, settings: array<string, string>} $expected
     */
    private function assertReference(PDO $pdo, string $schema, array $expected): void
    {
        $actual = $this->captureReference($pdo, $schema);
        foreach (['accounts', 'house', 'locations', 'thresholds'] as $name) {
            if ($actual[$name] !== $expected[$name]) {
                throw new RuntimeException('Reference ' . $name . ' does not match the empty Nest chain');
            }
        }
        $probe = $actual['settings'];
        $nest = $expected['settings'];
        foreach (self::INTAKE as $column) {
            if (($probe[$column] ?? '') !== 'false') {
                throw new RuntimeException('New mall intake extras are not off');
            }
            if (($nest[$column] ?? '') !== 'true') {
                throw new RuntimeException('Empty Nest chain intake extras are not on');
            }
            unset($probe[$column], $nest[$column]);
        }
        if ($probe !== $nest) {
            throw new RuntimeException('Store settings differ from the empty Nest chain');
        }
    }

    /**
     * @return list<string>
     */
    private function projection(PDO $pdo, string $schema, string $sql): array
    {
        $query = str_replace('__SCHEMA__', $this->ident($schema), $sql);
        $lines = [];
        foreach ($pdo->query($query)->fetchAll(PDO::FETCH_NUM) as $row) {
            $parts = [];
            foreach ($row as $value) {
                $parts[] = $value === null ? '' : (string) $value;
            }
            $lines[] = implode('|', $parts);
        }
        if ($lines === []) {
            throw new RuntimeException('Reference projection is empty');
        }
        return $lines;
    }

    /**
     * @return array<string, string>
     */
    private function settingsRow(PDO $pdo, string $schema): array
    {
        $select = $pdo->prepare(
            'SELECT column_name FROM information_schema.columns WHERE table_schema = ? AND table_name = ? ORDER BY ordinal_position',
        );
        $select->execute([$schema, 'store_settings']);
        $columns = [];
        foreach ($select->fetchAll() as $row) {
            $name = (string) $row['column_name'];
            if (preg_match('/^[a-z_][a-z0-9_]*$/', $name) !== 1) {
                throw new RuntimeException('Unexpected settings column');
            }
            $columns[] = $name;
        }
        if ($columns === []) {
            throw new RuntimeException('store_settings is missing');
        }
        $list = implode(', ', array_map(static fn (string $name): string => '"' . $name . '"::text', $columns));
        $row = $pdo->query('SELECT ' . $list . ' FROM ' . $this->ident($schema) . '.store_settings')->fetch();
        if ($row === false) {
            throw new RuntimeException('store_settings has no row');
        }
        $out = [];
        foreach ($columns as $name) {
            $value = $row[$name];
            $out[$name] = $value === null ? '' : (string) $value;
        }
        return $out;
    }

    private function schemaExists(PDO $pdo, string $schema): bool
    {
        $select = $pdo->prepare('SELECT 1 FROM pg_namespace WHERE nspname = ?');
        $select->execute([$schema]);
        return $select->fetchColumn() !== false;
    }

    private function ident(string $schema): string
    {
        if (preg_match('/^[a-z_][a-z0-9_]*$/', $schema) !== 1) {
            throw new RuntimeException('Schema name is not safe to read');
        }
        return '"' . $schema . '"';
    }

    /**
     * @return list<string>
     */
    private function queries(): array
    {
        return [
            "SELECT 'REL ' || c.relkind::text || ' ' || c.relname || COALESCE(' COMMENT ' || quote_literal(d.description), '')
             FROM pg_class c
             JOIN pg_namespace n ON n.oid = c.relnamespace
             LEFT JOIN pg_description d ON d.objoid = c.oid AND d.classoid = 'pg_class'::regclass AND d.objsubid = 0
             WHERE n.nspname = ? AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
             ORDER BY c.relkind, c.relname",
            "SELECT 'COL ' || c.relname || ' ' || row_number() OVER (PARTITION BY c.relname ORDER BY a.attnum)::text || ' ' || a.attname
                || ' ' || pg_catalog.format_type(a.atttypid, a.atttypmod)
                || ' null=' || a.attnotnull::text
                || ' identity=' || a.attidentity::text
                || ' generated=' || a.attgenerated::text
                || ' default=' || COALESCE(pg_get_expr(ad.adbin, ad.adrelid), '')
                || COALESCE(' comment=' || quote_literal(cd.description), '')
             FROM pg_attribute a
             JOIN pg_class c ON c.oid = a.attrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
             LEFT JOIN pg_description cd ON cd.objoid = c.oid AND cd.classoid = 'pg_class'::regclass AND cd.objsubid = a.attnum
             WHERE n.nspname = ? AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
             ORDER BY c.relname, a.attnum",
            "SELECT 'CON ' || c.relname || ' ' || con.contype::text || ' ' || con.conname || ' ' || pg_get_constraintdef(con.oid, true)
             FROM pg_constraint con
             JOIN pg_class c ON c.oid = con.conrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = ?
             ORDER BY c.relname, con.contype, con.conname, pg_get_constraintdef(con.oid, true)",
            "SELECT 'IDX ' || replace(pg_get_indexdef(i.indexrelid), n.nspname || '.', '')
             FROM pg_index i
             JOIN pg_class c ON c.oid = i.indrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = ?
             ORDER BY 1",
            "SELECT 'TRG ' || replace(pg_get_triggerdef(t.oid, true), n.nspname || '.', '')
             FROM pg_trigger t
             JOIN pg_class c ON c.oid = t.tgrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = ? AND NOT t.tgisinternal
             ORDER BY 1",
            "SELECT 'FN ' || p.proname || E'\\n' || pg_get_functiondef(p.oid)
             FROM pg_proc p
             JOIN pg_namespace n ON n.oid = p.pronamespace
             WHERE n.nspname = ?
             ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)",
            "SELECT 'SEQ ' || c.relname
                || ' start=' || s.seqstart::text
                || ' inc=' || s.seqincrement::text
                || ' min=' || s.seqmin::text
                || ' max=' || s.seqmax::text
                || ' cycle=' || s.seqcycle::text
             FROM pg_sequence s
             JOIN pg_class c ON c.oid = s.seqrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = ?
             ORDER BY c.relname",
            "SELECT 'TYPE ' || t.typname || ' ' || t.typtype::text || ' ' || pg_catalog.format_type(t.oid, NULL)
             FROM pg_type t
             JOIN pg_namespace n ON n.oid = t.typnamespace
             WHERE n.nspname = ? AND t.typtype IN ('e', 'c', 'd')
             ORDER BY t.typname",
        ];
    }
}
