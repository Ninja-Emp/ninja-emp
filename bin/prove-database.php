<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\DatabaseProof;
use EmpPos\Shared\Persistence\DemoBooks;
use EmpPos\Shared\Persistence\DemoSeeder;
use EmpPos\Shared\Persistence\Migrator;

$root = dirname(__DIR__);
$pdo = Database::connectFromEnv();
$seeder = new DemoSeeder($pdo, new Migrator($pdo, $root), new DemoBooks(), $root);
$proved = (new DatabaseProof($pdo, $seeder))->prove();
foreach ($proved as $name) {
    fwrite(STDOUT, $name . "\n");
}
fwrite(STDOUT, "database constraints hold\n");
