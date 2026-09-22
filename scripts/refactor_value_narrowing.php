<?php

declare(strict_types=1);

/**
 * One-shot refactor: replace unsafe `(string)`/`(int)`/`(float)` casts of
 * `mixed` with the total narrowing helpers in NinjaEMP\Db\Sql\Value.
 *
 * This is a development aid, not part of the runtime. It is idempotent: running
 * it twice is a no-op. It only rewrites the well-understood cast shapes; anything
 * unusual is left for a human (PHPStan will point at it).
 *
 * Usage: php scripts/refactor_value_narrowing.php [--dry-run]
 */

$dryRun = \in_array('--dry-run', $argv, true);
$root = \dirname(__DIR__) . '/src';

$iterator = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS),
);

$changedFiles = 0;
$changedSites = 0;

foreach ($iterator as $file) {
    if (!$file instanceof SplFileInfo || $file->getExtension() !== 'php') {
        continue;
    }

    $path = $file->getPathname();

    // The helper itself and the vendored PSR tree are off-limits.
    if (\str_contains($path, '/Db/Sql/Value.php') || \str_contains($path, '/Psr/')) {
        continue;
    }

    $original = (string) \file_get_contents($path);
    $code = $original;
    $sites = 0;

    // A) (string) ($X ?? 'D')  ->  Value::str($X ?? 'D')
    //    The coalesce is kept inside the call: it also suppresses the
    //    "undefined array key" warning, which a bare $X would not.
    $code = (string) \preg_replace_callback(
        '/\(string\) \((\$[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])*) \?\? (\'[^\']*\')\)/',
        static function (array $m) use (&$sites): string {
            $sites++;

            return \sprintf('Value::str(%s ?? %s)', $m[1], $m[2]);
        },
        $code,
    );

    // B) (string) ($X ?? $Y ?? 'D')  ->  Value::str($X ?? $Y ?? 'D')
    $code = (string) \preg_replace_callback(
        '/\(string\) \((\$[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])*) \?\? (\$[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])*) \?\? (\'[^\']*\')\)/',
        static function (array $m) use (&$sites): string {
            $sites++;

            return \sprintf('Value::str(%s ?? %s ?? %s)', $m[1], $m[2], $m[3]);
        },
        $code,
    );

    // C) (string) $X  ->  Value::str($X)   (simple var / array access / method chain)
    //    Possessive quantifiers stop the engine backtracking into an identifier,
    //    and the trailing (?![\w(]) guard leaves calls whose arguments contain
    //    nested parentheses (e.g. ->transactional(function () {…})) for a human.
    $code = (string) \preg_replace_callback(
        '/\(string\) (\$[A-Za-z_][A-Za-z0-9_]*+(?:\[[^\]]*+\])*+(?:->[A-Za-z_][A-Za-z0-9_]*+(?:\([^()]*+\))?+)*+)(?![\w(])/',
        static function (array $m) use (&$sites): string {
            $sites++;

            return \sprintf('Value::str(%s)', $m[1]);
        },
        $code,
    );

    // D) (int) $X  ->  Value::int($X)
    $code = (string) \preg_replace_callback(
        '/\(int\) (\$[A-Za-z_][A-Za-z0-9_]*+(?:\[[^\]]*+\])*+(?:->[A-Za-z_][A-Za-z0-9_]*+(?:\([^()]*+\))?+)*+)(?![\w(])/',
        static function (array $m) use (&$sites): string {
            $sites++;

            return \sprintf('Value::int(%s)', $m[1]);
        },
        $code,
    );

    // E) (float) $X  ->  Value::float($X)
    $code = (string) \preg_replace_callback(
        '/\(float\) (\$[A-Za-z_][A-Za-z0-9_]*+(?:\[[^\]]*+\])*+(?:->[A-Za-z_][A-Za-z0-9_]*+(?:\([^()]*+\))?+)*+)(?![\w(])/',
        static function (array $m) use (&$sites): string {
            $sites++;

            return \sprintf('Value::float(%s)', $m[1]);
        },
        $code,
    );

    if ($sites === 0 || $code === $original) {
        continue;
    }

    // Ensure the Value import is present (unless we are already in that namespace).
    if (!\str_contains($code, 'use NinjaEMP\\Db\\Sql\\Value;')
        && !\str_contains($code, 'namespace NinjaEMP\\Db\\Sql;')
    ) {
        $code = (string) \preg_replace(
            '/^(namespace [^;]+;\n)/m',
            "$1\nuse NinjaEMP\\Db\\Sql\\Value;\n",
            $code,
            1,
        );
    }

    $changedFiles++;
    $changedSites += $sites;

    if ($dryRun) {
        echo \sprintf("%4d  %s\n", $sites, \str_replace(\dirname(__DIR__) . '/', '', $path));
        continue;
    }

    \file_put_contents($path, $code);
}

echo \sprintf(
    "\n%s: %d sites in %d files\n",
    $dryRun ? 'DRY RUN' : 'REWRITTEN',
    $changedSites,
    $changedFiles,
);
