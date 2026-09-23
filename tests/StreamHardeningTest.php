<?php

declare(strict_types=1);

/**
 * Stream mode-detection hardening.
 *
 * The surviving mutants in Stream were the readable/writable predicates derived
 * from the fopen mode string, and the guard throws. These tests open real
 * resources in each mode so the predicates are exercised on both sides.
 */

use NinjaEMP\Http\Message\Stream;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Stream (hardening)');

    // ---- empty string stream ----------------------------------------------
    $empty = Stream::fromString();
    $t->assertSame(0, $empty->getSize(), 'empty stream has size 0');
    $t->assertSame('', (string) $empty, 'empty stream stringifies empty');
    $t->assertTrue($empty->eof(), 'empty stream is at eof');

    // ---- read-only resource: readable but not writable --------------------
    $path = tempnam(sys_get_temp_dir(), 'ninja-stream-');
    $t->assertTrue($path !== false, 'temp file created');
    file_put_contents($path, 'read-only');

    $ro = fopen($path, 'r');
    $t->assertTrue($ro !== false, 'read-only handle opened');
    $roStream = Stream::fromResource($ro);
    $t->assertTrue($roStream->isReadable(), 'r-mode stream is readable');
    $t->assertFalse($roStream->isWritable(), 'r-mode stream is not writable');
    $t->assertSame('read-only', $roStream->getContents(), 'r-mode stream reads its contents');
    $t->assertThrows(RuntimeException::class, fn () => $roStream->write('x'), 'writing to an r-mode stream throws');
    $roStream->close();

    // ---- write-only resource: writable but not readable -------------------
    $wo = fopen($path, 'w');
    $t->assertTrue($wo !== false, 'write-only handle opened');
    $woStream = Stream::fromResource($wo);
    $t->assertFalse($woStream->isReadable(), 'w-mode stream is not readable');
    $t->assertTrue($woStream->isWritable(), 'w-mode stream is writable');
    $t->assertSame(3, $woStream->write('abc'), 'w-mode stream writes');
    $t->assertThrows(RuntimeException::class, fn () => $woStream->read(1), 'reading a w-mode stream throws');
    $woStream->close();

    // ---- append mode is writable ------------------------------------------
    $ap = fopen($path, 'a');
    $t->assertTrue($ap !== false, 'append handle opened');
    $apStream = Stream::fromResource($ap);
    $t->assertTrue($apStream->isWritable(), 'a-mode stream is writable');
    $apStream->close();

    unlink($path);

    // ---- size is cached after the first fstat -----------------------------
    $cached = Stream::fromString('abcdef');
    $t->assertSame(6, $cached->getSize(), 'size computed once');
    $t->assertSame(6, $cached->getSize(), 'size returned from cache');
    $cached->seek(0, SEEK_END);
    $cached->write('g');
    $t->assertSame(7, $cached->getSize(), 'size recomputed after a write');

    // ---- getMetadata returns the whole array or a single key --------------
    $meta = Stream::fromString('x')->getMetadata();
    $t->assertTrue(is_array($meta), 'getMetadata() returns an array');
    $t->assertTrue(array_key_exists('seekable', $meta), 'metadata carries the seekable flag');
};
