<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use InvalidArgumentException;
use NinjaEMP\Domain\Pos\ShiftService;
use NinjaEMP\Tests\Support\FakeConnection;
use RuntimeException;

require_once __DIR__ . '/Support/FakeConnection.php';

/**
 * Hardening tests for ShiftService: they pin the exact SQL parameters, the
 * validation branches, the defaulting of the entry date, and the null-handling
 * of the drawer-balances-exactly path. These are the behaviours mutation
 * testing kept flagging as unverified.
 */
return static function (TestHarness $t): void {
    $t->suite('ShiftService (hardening)');

    // ---- createRegister ---------------------------------------------------

    $conn = new FakeConnection();
    $conn->on('INSERT INTO register', static fn () => [['id' => 'reg-9']]);
    $shifts = new ShiftService($conn);

    $regId = $shifts->createRegister('R9', 'Back Counter', 'loc-9', false);
    $t->assertSame('reg-9', $regId, 'createRegister returns the id');
    $t->assertSame(1, $conn->transactionCount, 'createRegister runs in a transaction');
    $regCall = $conn->findCall('INSERT INTO register');
    $t->assertSame('R9', $regCall['params']['code'], 'register code is bound');
    $t->assertSame('Back Counter', $regCall['params']['name'], 'register name is bound');
    $t->assertSame('loc-9', $regCall['params']['location'], 'register location is bound');
    $t->assertSame('false', $regCall['params']['active'], 'an inactive register binds the string false');

    // An active register binds the string true.
    $connActive = new FakeConnection();
    $connActive->on('INSERT INTO register', static fn () => [['id' => 'reg-10']]);
    (new ShiftService($connActive))->createRegister('R10', 'Front', null, true);
    $activeCall = $connActive->findCall('INSERT INTO register');
    $t->assertSame('true', $activeCall['params']['active'], 'an active register binds the string true');
    $t->assertSame(null, $activeCall['params']['location'], 'a null location is bound as null');

    // Blank code / name are rejected before any SQL is issued.
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new ShiftService(new FakeConnection()))->createRegister('   ', 'Front'),
        'a blank register code is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new ShiftService(new FakeConnection()))->createRegister('R1', '  '),
        'a blank register name is rejected',
    );

    // A missing RETURNING row is a hard failure.
    $connNoRow = new FakeConnection();
    $connNoRow->on('INSERT INTO register', static fn () => null);
    $t->assertThrows(
        RuntimeException::class,
        static fn () => (new ShiftService($connNoRow))->createRegister('R1', 'Front'),
        'a register insert that returns no row fails loudly',
    );

    // ---- openShift --------------------------------------------------------

    $connOpen = new FakeConnection();
    $connOpen->on('INSERT INTO shift', static fn () => [['id' => 'shift-9']]);
    $shiftId = (new ShiftService($connOpen))->openShift('reg-9', '150.5', 'party-9', 'EUR');
    $t->assertSame('shift-9', $shiftId, 'openShift returns the shift id');
    $openCall = $connOpen->findCall('INSERT INTO shift');
    $t->assertSame('reg-9', $openCall['params']['register'], 'shift register is bound');
    $t->assertSame('party-9', $openCall['params']['opened_by'], 'shift opener is bound');
    $t->assertSame('150.5000', $openCall['params']['float'], 'opening float is normalised to 4dp');
    $t->assertSame('EUR', $openCall['params']['currency'], 'shift currency is bound');

    // A negative float is rejected.
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => (new ShiftService(new FakeConnection()))->openShift('reg-9', '-0.01'),
        'a negative opening float is rejected',
    );

    // A missing RETURNING row is a hard failure.
    $connOpenNoRow = new FakeConnection();
    $connOpenNoRow->on('INSERT INTO shift', static fn () => null);
    $t->assertThrows(
        RuntimeException::class,
        static fn () => (new ShiftService($connOpenNoRow))->openShift('reg-9'),
        'a shift insert that returns no row fails loudly',
    );

    // ---- closeShift -------------------------------------------------------

    $connClose = new FakeConnection();
    $connClose->on('post_shift_close', static fn () => 'entry-9');
    $entry = (new ShiftService($connClose))->closeShift('shift-9', '300.00', '2026-02-01', 'key-9');
    $t->assertSame('entry-9', $entry, 'closeShift returns the entry id');
    $closeCall = $connClose->findCall('post_shift_close');
    $t->assertSame('shift-9', $closeCall['params']['shift'], 'closeShift binds the shift id');
    $t->assertSame('300.00', $closeCall['params']['counted'], 'closeShift binds the counted cash');
    $t->assertSame('2026-02-01', $closeCall['params']['date'], 'closeShift binds the entry date');
    $t->assertSame('key-9', $closeCall['params']['key'], 'closeShift binds the idempotency key');

    // With no date supplied, today is used.
    $connDefault = new FakeConnection();
    $connDefault->on('post_shift_close', static fn () => 'entry-10');
    (new ShiftService($connDefault))->closeShift('shift-10', '10.00');
    $defaultCall = $connDefault->findCall('post_shift_close');
    $t->assertSame(date('Y-m-d'), $defaultCall['params']['date'], 'closeShift defaults the entry date to today');
    $t->assertSame(null, $defaultCall['params']['key'], 'closeShift defaults the idempotency key to null');

    // A balanced drawer (NULL from the posting function) returns null.
    $connBalanced = new FakeConnection();
    $connBalanced->on('post_shift_close', static fn () => null);
    $t->assertSame(null, (new ShiftService($connBalanced))->closeShift('shift-11', '100.00'), 'a balanced drawer returns null');

    // ---- previewClose -----------------------------------------------------

    $connPreview = new FakeConnection();
    $connPreview->on('SELECT opening_float', static fn () => [['opening_float' => '100.0000', 'currency' => 'USD']]);
    $connPreview->on('SELECT COALESCE(sum(pt.amount)', static fn () => '75.0000');
    $preview = (new ShiftService($connPreview))->previewClose('shift-9', '200.00');
    $t->assertSame(
        [
            'opening_float' => '100.0000',
            'cash_in' => '75.0000',
            'expected' => '175.0000',
            'counted' => '200.0000',
            'over_short' => '25.0000',
            'currency' => 'USD',
        ],
        $preview,
        'previewClose returns the full over/short breakdown',
    );

    // A short drawer yields a negative over/short.
    $connShort = new FakeConnection();
    $connShort->on('SELECT opening_float', static fn () => [['opening_float' => '100.0000', 'currency' => 'USD']]);
    $connShort->on('SELECT COALESCE(sum(pt.amount)', static fn () => '0.0000');
    $short = (new ShiftService($connShort))->previewClose('shift-9', '90.00');
    $t->assertSame('-10.0000', $short['over_short'], 'a short drawer yields a negative over/short');

    // ---- openShiftFor -----------------------------------------------------

    $connFor = new FakeConnection();
    $connFor->on('SELECT id, shift_no, opened_at', static fn () => [[
        'id' => 'shift-9',
        'shift_no' => '7',
        'opened_at' => '2026-02-01 09:00:00',
        'opening_float' => '100.0000',
        'currency' => 'USD',
    ]]);
    $open = (new ShiftService($connFor))->openShiftFor('reg-9');
    $t->assertSame('shift-9', $open['id'], 'openShiftFor returns the open shift row');
    $t->assertSame('USD', $open['currency'], 'openShiftFor returns the currency');

    // No open shift yields null.
    $connNone = new FakeConnection();
    $connNone->on('SELECT id, shift_no, opened_at', static fn () => null);
    $t->assertSame(null, (new ShiftService($connNone))->openShiftFor('reg-9'), 'no open shift yields null');
};
