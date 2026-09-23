<?php

declare(strict_types=1);

use NinjaEMP\Db\Sql\PlaceholderRewriter;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('PlaceholderRewriter');
    $r = new PlaceholderRewriter();

    // Basic rewrite + ordered binds. Named parameters become unique PDO-safe
    // named placeholders (:p1, :p2, …) — PDO's pgsql driver binds literal `$1`
    // as NULL, so we must stay on the named path.
    $out = $r->rewrite('SELECT * FROM t WHERE a = :a AND b = :b', ['a' => 1, 'b' => 2]);
    $t->assertSame('SELECT * FROM t WHERE a = :p1 AND b = :p2', $out['sql'], 'basic rewrite');
    $t->assertSame(['p1' => 1, 'p2' => 2], $out['params'], 'ordered binds');

    // Reuse is legal: same name -> a fresh placeholder per occurrence.
    $out = $r->rewrite('SELECT :x, :x, :y', ['x' => 'a', 'y' => 'b']);
    $t->assertSame('SELECT :p1, :p2, :p3', $out['sql'], 'reused placeholder');
    $t->assertSame(['p1' => 'a', 'p2' => 'a', 'p3' => 'b'], $out['params'], 'reused bound per occurrence');

    // Order of first appearance drives numbering, not the params array order.
    $out = $r->rewrite('SELECT :b, :a', ['a' => 1, 'b' => 2]);
    $t->assertSame('SELECT :p1, :p2', $out['sql'], 'numbering by appearance');
    $t->assertSame(['p1' => 2, 'p2' => 1], $out['params'], 'binds follow appearance');

    // :: cast is not a parameter.
    $out = $r->rewrite('SELECT :id::uuid, :n::numeric', ['id' => 'x', 'n' => '1']);
    $t->assertSame('SELECT :p1::uuid, :p2::numeric', $out['sql'], 'cast operator preserved');
    $t->assertSame(['p1' => 'x', 'p2' => '1'], $out['params'], 'cast binds');

    // :name inside a single-quoted literal is ignored.
    $out = $r->rewrite("SELECT ':notaparam', :real", ['real' => 1]);
    $t->assertSame("SELECT ':notaparam', :p1", $out['sql'], 'single-quote literal ignored');
    $t->assertSame(['p1' => 1], $out['params'], 'only real param bound');

    // Doubled quote inside a literal.
    $out = $r->rewrite("SELECT 'it''s :x', :y", ['y' => 2]);
    $t->assertSame("SELECT 'it''s :x', :p1", $out['sql'], 'escaped quote handled');
    $t->assertSame(['p1' => 2], $out['params'], 'escaped-quote binds');

    // Double-quoted identifier is ignored.
    $out = $r->rewrite('SELECT ":col", :v', ['v' => 3]);
    $t->assertSame('SELECT ":col", :p1', $out['sql'], 'double-quote identifier ignored');

    // Dollar-quoted string is ignored.
    $out = $r->rewrite('SELECT $$ :x $$, :y', ['y' => 4]);
    $t->assertSame('SELECT $$ :x $$, :p1', $out['sql'], 'dollar-quote ignored');
    $t->assertSame(['p1' => 4], $out['params'], 'dollar-quote binds');

    // Tagged dollar-quote.
    $out = $r->rewrite('SELECT $tag$ :x $tag$, :y', ['y' => 5]);
    $t->assertSame('SELECT $tag$ :x $tag$, :p1', $out['sql'], 'tagged dollar-quote ignored');

    // Line comment ignored.
    $out = $r->rewrite("SELECT 1 -- :x\n, :y", ['y' => 6]);
    $t->assertSame("SELECT 1 -- :x\n, :p1", $out['sql'], 'line comment ignored');

    // Block comment ignored.
    $out = $r->rewrite('SELECT /* :x */ :y', ['y' => 7]);
    $t->assertSame('SELECT /* :x */ :p1', $out['sql'], 'block comment ignored');

    // Missing param throws.
    $t->assertThrows(InvalidArgumentException::class, fn () => $r->rewrite('SELECT :a', []), 'missing param throws');

    // Unused param throws.
    $t->assertThrows(InvalidArgumentException::class, fn () => $r->rewrite('SELECT 1', ['a' => 1]), 'unused param throws');

    // No params at all is a no-op.
    $out = $r->rewrite('SELECT 1', []);
    $t->assertSame('SELECT 1', $out['sql'], 'no-op');
    $t->assertSame([], $out['params'], 'no binds');
};
