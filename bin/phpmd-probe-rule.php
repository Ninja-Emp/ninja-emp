<?php

declare(strict_types=1);

$rule = $argv[1] ?? '';
if ($rule === '' || !str_contains($rule, '/')) {
    fwrite(STDERR, "Usage: composer run probe:phpmd -- rulesets/codesize.xml/ExcessiveClassLength\n");
    exit(1);
}

$ruleset = sys_get_temp_dir() . '/emp-pos-phpmd-probe.xml';
$xml = '<?xml version="1.0"?><ruleset name="probe"><rule ref="' . htmlspecialchars($rule, ENT_XML1) . '"/></ruleset>';
if (file_put_contents($ruleset, $xml) === false) {
    fwrite(STDERR, "Could not write the probe ruleset\n");
    exit(1);
}

$command = escapeshellarg(dirname(__DIR__) . '/vendor/bin/phpmd') . ' src text ' . escapeshellarg($ruleset);
passthru($command, $exit);
exit($exit);
