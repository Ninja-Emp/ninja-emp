<?php

declare(strict_types=1);

namespace EmpPos\Tests;

use EmpPos\Bootstrap\Kernel;
use EmpPos\Http\Request;
use EmpPos\Http\Response;
use EmpPos\Shared\Ledger\JournalLine;
use EmpPos\Shared\Ledger\Money;
use EmpPos\Shared\Ledger\PostedJournal;
use EmpPos\Shared\Ledger\Posting;
use EmpPos\Shared\Persistence\CatalogProof;
use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\DatabaseProof;
use EmpPos\Shared\Persistence\DemoBooks;
use EmpPos\Shared\Persistence\DemoSeeder;
use EmpPos\Shared\Persistence\Migrator;
use EmpPos\Shared\Scalar;
use PHPUnit\Framework\TestCase;

final class BarTest extends TestCase
{
    public function testValueObjects(): void
    {
        $request = new Request('POST', '/api/v1/journals', ['x-csrf-token' => 'a'], ['session' => 'b'], '{"currency":"USD"}');
        self::assertSame('POST', $request->method());
        self::assertSame('/api/v1/journals', $request->path());
        self::assertSame('a', $request->header('X-CSRF-Token'));
        self::assertSame('b', $request->cookie('session'));
        self::assertSame('USD', $request->json()['currency']);
        self::assertSame([], (new Request('GET', '/', [], [], ''))->json());
        $response = Response::json(201, ['ok' => true]);
        self::assertSame(201, $response->status());
        self::assertSame(['ok' => true], $response->body());
        self::assertSame([], $response->cookies());
        self::assertNull(Response::empty(204)->body());
        self::assertSame("ok\n", (new Kernel())->health());
        $posted = new PostedJournal('id', '1', 'key', false);
        self::assertSame('id', $posted->journalId());
        self::assertSame('1', $posted->journalNo());
        self::assertSame('key', $posted->postingKey());
        self::assertFalse($posted->reused());
        $posting = new Posting('k', '2026-09-12', '2026-09-12T18:00:00.000Z', 'USD', 'owner_capital', 'Open', [
            new JournalLine('1010', Money::of(1, 'USD'), Money::zero('USD'), null, null, 'memo'),
        ], 'ref', true, 'jid');
        self::assertSame('k', $posting->postingKey());
        self::assertSame('2026-09-12', $posting->postingDate());
        self::assertSame('2026-09-12T18:00:00.000Z', $posting->occurredAt());
        self::assertSame('USD', $posting->currency());
        self::assertSame('owner_capital', $posting->sourceType());
        self::assertSame('Open', $posting->description());
        self::assertCount(1, $posting->lines());
        self::assertSame('memo', $posting->lines()[0]->memo());
        self::assertSame('ref', $posting->sourceReference());
        self::assertTrue($posting->reversal());
        self::assertSame('jid', $posting->reversesJournalId());
        self::assertSame('x', Scalar::text(['k' => 'x'], 'k'));
        self::assertNull(Scalar::nullableText(['k' => null], 'k'));
    }

    public function testHttpProof(): void
    {
        require_once dirname(__DIR__) . '/bin/prove-http.php';
        proveHttp();
        self::assertTrue(true);
    }

    public function testLedgerProof(): void
    {
        require_once dirname(__DIR__) . '/bin/prove-ledger.php';
        proveLedger();
        self::assertTrue(true);
    }

    public function testDatabaseProof(): void
    {
        $root = dirname(__DIR__);
        $pdo = Database::connectFromEnv();
        $seeder = new DemoSeeder($pdo, new Migrator($pdo, $root), new DemoBooks(), $root);
        $proved = (new DatabaseProof($pdo, $seeder))->prove();
        self::assertNotEmpty($proved);
        (new DemoBooks())->assertSaturday($pdo);
    }

    public function testCatalogProof(): void
    {
        $root = dirname(__DIR__);
        $pos = Database::connectFromEnv();
        $proof = new CatalogProof(new Migrator($pos, $root));
        $proof->prove(
            $pos,
            Database::connect('postgres://emp:emp@127.0.0.1:5433/emp'),
            Database::connect('postgres://emp:emp@127.0.0.1:5433/emp_pos_nest_ref'),
        );
        self::assertTrue(true);
    }
}
