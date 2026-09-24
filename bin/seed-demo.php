<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\DemoBooks;
use EmpPos\Shared\Persistence\DemoSeeder;
use EmpPos\Shared\Persistence\Migrator;
use EmpPos\Shared\Persistence\WipeRefused;

$root = dirname(__DIR__);
$pdo = Database::connectFromEnv();
$seeder = new DemoSeeder($pdo, new Migrator($pdo, $root), new DemoBooks(), $root);

try {
    $seeder->reseed();
} catch (WipeRefused $refused) {
    fwrite(STDERR, $refused->getMessage() . "\n");
    exit(1);
}

fwrite(STDOUT, "demo seeded\n");
