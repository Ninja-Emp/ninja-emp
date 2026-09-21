<?php

declare(strict_types=1);

use NinjaEMP\Db\Type\TypeMapper;
use NinjaEMP\Money\Money;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('TypeMapper');
    $m = new TypeMapper();

    // numeric -> Money (string-backed, never float).
    $row = $m->map(['total' => '123.4500'], ['total' => 'USD']);
    $t->assertTrue($row['total'] instanceof Money, 'numeric becomes Money');
    $t->assertSame('123.4500', $row['total']->amount(), 'money preserves exact string');
    $t->assertSame('USD', $row['total']->currency()->code(), 'money carries currency');

    // null stays null.
    $row = $m->map(['total' => null], ['total' => 'USD']);
    $t->assertSame(null, $row['total'], 'null money stays null');

    // jsonb -> array.
    $row = $m->map(['meta' => '{"a":1}'], [], ['meta']);
    $t->assertSame(['a' => 1], $row['meta'], 'jsonb decoded');

    // boolean.
    $row = $m->map(['active' => 't'], [], [], ['active']);
    $t->assertSame(true, $row['active'], 't -> true');
    $row = $m->map(['active' => 'f'], [], [], ['active']);
    $t->assertSame(false, $row['active'], 'f -> false');

    // bigint within range -> int.
    $row = $m->map(['n' => '42'], [], [], [], ['n']);
    $t->assertSame(42, $row['n'], 'bigint -> int');

    // bigint beyond PHP_INT_MAX stays string (no silent truncation).
    $row = $m->map(['n' => '99999999999999999999'], [], [], [], ['n']);
    $t->assertSame('99999999999999999999', $row['n'], 'huge bigint stays string');

    // timestamptz -> DateTimeImmutable UTC.
    $row = $m->map(['at' => '2026-01-02 03:04:05+00'], [], [], [], [], ['at']);
    $t->assertTrue($row['at'] instanceof DateTimeImmutable, 'timestamptz -> DateTimeImmutable');
    $t->assertSame('2026-01-02 03:04:05', $row['at']->format('Y-m-d H:i:s'), 'instant preserved');

    // date -> midnight UTC.
    $row = $m->map(['d' => '2026-01-02'], [], [], [], [], ['d']);
    $t->assertSame('2026-01-02 00:00:00', $row['d']->format('Y-m-d H:i:s'), 'date -> midnight UTC');

    // untyped passthrough.
    $row = $m->map(['name' => 'Acme']);
    $t->assertSame('Acme', $row['name'], 'untyped passthrough');
};
