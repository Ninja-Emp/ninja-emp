<?php

declare(strict_types=1);

/**
 * PlaceholderRewriter edge-case hardening.
 *
 * The surviving mutants were the unterminated-literal branches (quote, dollar
 * quote, block comment, line comment at EOF), the `$`-not-a-delimiter branch,
 * and the error-message construction. These tests drive each lexical state to
 * its boundary.
 */

use NinjaEMP\Db\Sql\PlaceholderRewriter;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('PlaceholderRewriter (hardening)');
    $r = new PlaceholderRewriter();

    // ---- unterminated single-quoted literal runs to EOF -------------------
    $out = $r->rewrite("SELECT ':x", []);
    $t->assertSame("SELECT ':x", $out['sql'], 'unterminated single quote is copied verbatim');
    $t->assertSame([], $out['params'], 'unterminated single quote binds nothing');

    // ---- unterminated double-quoted identifier runs to EOF ----------------
    $out = $r->rewrite('SELECT ":x', []);
    $t->assertSame('SELECT ":x', $out['sql'], 'unterminated double quote is copied verbatim');

    // ---- unterminated dollar-quoted string runs to EOF --------------------
    $out = $r->rewrite('SELECT $tag$ :x', []);
    $t->assertSame('SELECT $tag$ :x', $out['sql'], 'unterminated dollar quote is copied verbatim');
    $t->assertSame([], $out['params'], 'unterminated dollar quote binds nothing');

    // ---- unterminated block comment runs to EOF ---------------------------
    $out = $r->rewrite('SELECT /* :x', []);
    $t->assertSame('SELECT /* :x', $out['sql'], 'unterminated block comment is copied verbatim');

    // ---- line comment with no trailing newline ----------------------------
    $out = $r->rewrite('SELECT 1 -- :x', []);
    $t->assertSame('SELECT 1 -- :x', $out['sql'], 'line comment at EOF is copied verbatim');

    // ---- a `$` that is not a dollar-quote opener is left alone ------------
    $out = $r->rewrite('SELECT $foo, :a', ['a' => 1]);
    $t->assertSame('SELECT $foo, $1', $out['sql'], 'bare $ is not treated as a delimiter');
    $t->assertSame([1], $out['params'], 'bare $ binds nothing');

    // ---- empty dollar-quote tag ($$) --------------------------------------
    $out = $r->rewrite('SELECT $$ :x $$, :y', ['y' => 2]);
    $t->assertSame('SELECT $$ :x $$, $1', $out['sql'], 'empty dollar-quote tag ignored');

    // ---- parameter at the very end of the statement -----------------------
    $out = $r->rewrite('SELECT :a', ['a' => 9]);
    $t->assertSame('SELECT $1', $out['sql'], 'trailing parameter rewritten');
    $t->assertSame([9], $out['params'], 'trailing parameter bound');

    // ---- cast operator at the very end ------------------------------------
    $out = $r->rewrite('SELECT :a::', ['a' => 1]);
    $t->assertSame('SELECT $1::', $out['sql'], 'trailing cast preserved');

    // ---- a lone colon is not a parameter ----------------------------------
    $out = $r->rewrite('SELECT a : b', []);
    $t->assertSame('SELECT a : b', $out['sql'], 'lone colon is copied verbatim');

    // ---- a colon followed by a digit is not a parameter -------------------
    $out = $r->rewrite('SELECT :1', []);
    $t->assertSame('SELECT :1', $out['sql'], 'colon-digit is not a parameter');

    // ---- missing-parameter message names the parameter --------------------
    try {
        $r->rewrite('SELECT :missing', []);
        $t->assertTrue(false, 'missing parameter should throw');
    } catch (InvalidArgumentException $e) {
        $t->assertTrue(str_contains($e->getMessage(), ':missing'), 'missing-parameter message names the parameter');
    }

    // ---- unused-parameter message lists the parameter ---------------------
    try {
        $r->rewrite('SELECT 1', ['unused' => 1]);
        $t->assertTrue(false, 'unused parameter should throw');
    } catch (InvalidArgumentException $e) {
        $t->assertTrue(str_contains($e->getMessage(), ':unused'), 'unused-parameter message names the parameter');
    }

    // ---- multiple unused parameters are all listed ------------------------
    try {
        $r->rewrite('SELECT 1', ['a' => 1, 'b' => 2]);
        $t->assertTrue(false, 'unused parameters should throw');
    } catch (InvalidArgumentException $e) {
        $t->assertTrue(str_contains($e->getMessage(), ':a') && str_contains($e->getMessage(), ':b'), 'all unused parameters listed');
    }

    // ---- a name reused many times binds once ------------------------------
    $out = $r->rewrite('SELECT :x, :x, :x', ['x' => 'v']);
    $t->assertSame('SELECT $1, $1, $1', $out['sql'], 'repeated name reuses one placeholder');
    $t->assertSame(['v'], $out['params'], 'repeated name binds once');
};
