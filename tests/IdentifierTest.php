<?php

declare(strict_types=1);

use NinjaEMP\Db\Sql\Identifier;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Identifier');

    $t->assertTrue(Identifier::isValid('tenant_acme'), 'valid snake_case');
    $t->assertTrue(Identifier::isValid('_x'), 'leading underscore');
    $t->assertTrue(Identifier::isValid('a1_b2'), 'digits allowed after first char');

    $t->assertFalse(Identifier::isValid('Tenant'), 'uppercase rejected');
    $t->assertFalse(Identifier::isValid('1tenant'), 'leading digit rejected');
    $t->assertFalse(Identifier::isValid('tenant-acme'), 'hyphen rejected');
    $t->assertFalse(Identifier::isValid('tenant;drop'), 'injection rejected');
    $t->assertFalse(Identifier::isValid(''), 'empty rejected');

    $t->assertSame('"tenant_acme"', Identifier::of('tenant_acme')->quoted(), 'quoted output');
    $t->assertThrows(InvalidArgumentException::class, fn () => Identifier::of('bad-name'), 'of() throws on unsafe');
};
