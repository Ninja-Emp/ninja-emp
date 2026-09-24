<?php

declare(strict_types=1);

require dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\Migrator;

$root = dirname(__DIR__);
$migrator = new Migrator(Database::connectFromEnv(), $root);
$kind = $argv[1] ?? 'shared';

if ($kind === 'shared') {
    $migrator->migrateShared();
    fwrite(STDOUT, "shared migrated\n");
    exit(0);
}

if ($kind === 'tenant') {
    $schema = $argv[2] ?? '';
    if ($schema === '') {
        fwrite(STDERR, "usage: php bin/migrate.php tenant <schema>\n");
        exit(1);
    }
    $migrator->migrateTenant($schema);
    fwrite(STDOUT, "tenant migrated\n");
    exit(0);
}

fwrite(STDERR, "usage: php bin/migrate.php [shared|tenant <schema>]\n");
exit(1);
