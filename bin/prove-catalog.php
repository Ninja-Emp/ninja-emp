<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Shared\Persistence\CatalogProof;
use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\Migrator;

$root = dirname(__DIR__);
$pos = Database::connectFromEnv();
$nestUrl = getenv('EMP_NEST_DATABASE_URL');
if (!is_string($nestUrl) || $nestUrl === '') {
    $nestUrl = 'postgres://emp:emp@127.0.0.1:5433/emp';
}
$referenceUrl = getenv('EMP_NEST_REF_DATABASE_URL');
if (!is_string($referenceUrl) || $referenceUrl === '') {
    $referenceUrl = 'postgres://emp:emp@127.0.0.1:5433/emp_pos_nest_ref';
}

$proof = new CatalogProof(new Migrator($pos, $root));
$proof->prove($pos, Database::connect($nestUrl), Database::connect($referenceUrl));
fwrite(STDOUT, "catalog matches\n");
