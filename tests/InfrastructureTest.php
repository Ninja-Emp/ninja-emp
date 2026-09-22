<?php

declare(strict_types=1);

use NinjaEMP\Db\ErrorMapper;
use NinjaEMP\Db\Exception\AppendOnlyViolationException;
use NinjaEMP\Db\Exception\ConflictException;
use NinjaEMP\Db\Exception\ConstraintViolationException;
use NinjaEMP\Db\Exception\DatabaseException;
use NinjaEMP\Db\Exception\LedgerBalanceException;
use NinjaEMP\Db\Exception\ReferenceException;
use NinjaEMP\Db\Exception\RetryableException;
use NinjaEMP\Db\Row;
use NinjaEMP\Db\Sql\Value;
use NinjaEMP\Db\TenantContext;
use NinjaEMP\Domain\Reporting\ReportingService;
use NinjaEMP\Http\Emitter;
use NinjaEMP\Http\Message\Response;
use NinjaEMP\Ledger\JournalEntry;
use NinjaEMP\Ledger\JournalLine;
use NinjaEMP\Ledger\LedgerService;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;
use NinjaEMP\Tenancy\TenantContextHolder;
use NinjaEMP\Tests\Support\FakeConnection;
use NinjaEMP\Tests\TestHarness;

require_once __DIR__ . '/Support/FakeConnection.php';

return static function (TestHarness $t): void {
    $t->suite('Infrastructure');

    // ---- Row --------------------------------------------------------------

    $row = new Row(['id' => 'abc', 'amount' => '1.0000', 'n' => 3]);
    $t->assertSame(['id' => 'abc', 'amount' => '1.0000', 'n' => 3], $row->toArray(), 'row toArray');
    $t->assertTrue($row->has('id'), 'row has existing column');
    $t->assertFalse($row->has('missing'), 'row has missing column');
    $t->assertSame('abc', $row->get('id'), 'row get');
    $t->assertSame('fallback', $row->get('missing', 'fallback'), 'row get default');
    $t->assertSame('abc', $row->require('id'), 'row require present');
    $t->assertThrows(OutOfBoundsException::class, fn () => $row->require('missing'), 'row require absent throws');
    $t->assertSame(3, count($row), 'row count');

    $iterated = [];

    foreach ($row as $key => $value) {
        $iterated[$key] = $value;
    }
    $t->assertSame($row->toArray(), $iterated, 'row iterates its values');

    $t->assertTrue(isset($row['id']), 'offsetExists string key');
    $t->assertFalse(isset($row[0]), 'offsetExists non-string key');
    $t->assertSame('abc', $row['id'], 'offsetGet');
    $t->assertSame(null, $row['missing'], 'offsetGet missing is null');
    $t->assertThrows(LogicException::class, static function () use ($row): void {
        $row['x'] = 'y';
    }, 'row is immutable (set)');
    $t->assertThrows(LogicException::class, static function () use ($row): void {
        unset($row['id']);
    }, 'row is immutable (unset)');

    // ---- Value ------------------------------------------------------------

    $t->assertSame('abc', Value::str('abc'), 'str from string');
    $t->assertSame('5', Value::str(5), 'str from int');
    $t->assertSame('1.5', Value::str(1.5), 'str from float');
    $t->assertSame('1', Value::str(true), 'str from bool');
    $t->assertSame('def', Value::str(null, 'def'), 'str from null uses default');
    $t->assertSame('def', Value::str([], 'def'), 'str from array uses default');

    $t->assertSame(null, Value::nullableStr(null), 'nullableStr null');
    $t->assertSame('x', Value::nullableStr('x'), 'nullableStr string');
    $t->assertSame('7', Value::nullableStr(7), 'nullableStr int');
    $t->assertSame(null, Value::nullableStr([]), 'nullableStr array -> null');

    $t->assertSame('3', Value::num(3), 'num from int');
    $t->assertSame('3.25', Value::num(3.25), 'num from float');
    $t->assertSame('10', Value::num('10'), 'num from numeric string');
    $t->assertSame('0', Value::num('abc'), 'num from non-numeric uses default');
    $t->assertSame('9', Value::num(null, '9'), 'num custom default');

    $t->assertSame(4, Value::int(4), 'int from int');
    $t->assertSame(4, Value::int(4.9), 'int from float truncates');
    $t->assertSame(4, Value::int('4'), 'int from numeric string');
    $t->assertSame(0, Value::int('x'), 'int from non-numeric default');
    $t->assertSame(7, Value::int(null, 7), 'int custom default');

    $t->assertSame(2.0, Value::float(2), 'float from int');
    $t->assertSame(2.5, Value::float(2.5), 'float from float');
    $t->assertSame(2.5, Value::float('2.5'), 'float from numeric string');
    $t->assertSame(0.0, Value::float('x'), 'float from non-numeric default');
    $t->assertSame(1.5, Value::float(null, 1.5), 'float custom default');

    $t->assertTrue(Value::bool(true), 'bool from true');
    $t->assertFalse(Value::bool(false), 'bool from false');
    $t->assertTrue(Value::bool(1), 'bool from int 1');
    $t->assertFalse(Value::bool(0), 'bool from int 0');
    $t->assertTrue(Value::bool('yes'), 'bool from yes');
    $t->assertFalse(Value::bool('no'), 'bool from no');
    $t->assertTrue(Value::bool('garbage', true), 'bool from garbage uses default');
    $t->assertFalse(Value::bool([], false), 'bool from array uses default');

    // ---- ErrorMapper ------------------------------------------------------

    $mapper = new ErrorMapper();
    $pdo = static function (string $sqlstate, string $message = 'boom'): PDOException {
        $e = new PDOException($message);
        $prop = new ReflectionProperty(Exception::class, 'code');
        $prop->setValue($e, $sqlstate);

        return $e;
    };

    $t->assertSame(ConstraintViolationException::class, $mapper->map($pdo('23514', 'check failed'))::class, '23514 -> constraint violation');
    $t->assertSame(LedgerBalanceException::class, $mapper->map($pdo('23514', 'balance mismatch'))::class, '23514 balance -> ledger balance');
    $t->assertSame(LedgerBalanceException::class, $mapper->map($pdo('23514', 'assert_entry_balanced failed'))::class, '23514 assert -> ledger balance');
    $t->assertSame(ReferenceException::class, $mapper->map($pdo('23503'))::class, '23503 -> reference');
    $t->assertSame(ConflictException::class, $mapper->map($pdo('23505'))::class, '23505 -> conflict');
    $t->assertSame(AppendOnlyViolationException::class, $mapper->map($pdo('55000'))::class, '55000 -> append-only');
    $t->assertSame(RetryableException::class, $mapper->map($pdo('40001'))::class, '40001 -> retryable');
    $t->assertSame(DatabaseException::class, $mapper->map($pdo('99999'))::class, 'unknown -> database');
    $t->assertSame(DatabaseException::class, $mapper->map($pdo(''))::class, 'empty code -> database');

    $mapped = $mapper->map($pdo('23505', 'dup'));
    $t->assertSame('23505', $mapped->sqlState(), 'mapped exception carries sqlstate');

    // ---- TenantContextHolder ---------------------------------------------

    $holder = new TenantContextHolder();
    $t->assertFalse($holder->has(), 'holder starts empty');
    $t->assertThrows(RuntimeException::class, fn () => $holder->get(), 'get before set throws');

    $context = new class () implements TenantContext {
        public function tenantId(): string
        {
            return 'tenant-1';
        }

        public function actorId(): ?string
        {
            return null;
        }

        public function schema(): string
        {
            return 'tenant_demo';
        }
    };
    $holder->set($context);
    $t->assertTrue($holder->has(), 'holder has context after set');
    $t->assertSame('tenant-1', $holder->get()->tenantId(), 'holder returns context');
    $holder->clear();
    $t->assertFalse($holder->has(), 'holder cleared');

    // ---- Emitter ----------------------------------------------------------

    $emitter = new Emitter();
    ob_start();
    $emitter->emit(new Response(200, 'emitted-body', ['X-Emit' => 'yes']));
    $emitted = ob_get_clean();
    $t->assertSame('emitted-body', $emitted, 'emitter writes the body');

    // ---- LedgerService ----------------------------------------------------

    $ledgerConn = new FakeConnection();
    $ledgerConn->on('posting_account', static fn (): string => 'acct-uuid');
    $ledgerConn->on('post_journal_entry', static fn (): string => 'entry-uuid');
    $ledgerConn->on('reverse_journal_entry', static fn (): string => 'reversal-uuid');
    $ledger = new LedgerService($ledgerConn);

    $usd = Currency::usd();
    $entry = new JournalEntry('2026-01-02', 'Sale', 'pos', 'sale-1', 'key-1', [
        JournalLine::debit('undeposited_funds', Money::of('10', $usd)),
        JournalLine::credit('sales_revenue', Money::of('10', $usd)),
    ]);
    $t->assertSame('entry-uuid', $ledger->post($entry), 'ledger post returns entry id');
    $t->assertSame(1, $ledgerConn->transactionCount, 'ledger post runs in a transaction');
    $t->assertTrue($ledgerConn->calledWith('posting_account'), 'ledger resolves posting roles');
    $t->assertTrue($ledgerConn->calledWith('post_journal_entry'), 'ledger calls post_journal_entry');

    // A line addressed by an explicit account id skips role resolution.
    $directConn = new FakeConnection();
    $directConn->on('post_journal_entry', static fn (): string => 'entry-2');
    $direct = new LedgerService($directConn);
    $directEntry = new JournalEntry('2026-01-02', 'Direct', 'pos', null, null, [
        JournalLine::debitAccount('acct-a', Money::of('5', $usd)),
        JournalLine::creditAccount('acct-b', Money::of('5', $usd)),
    ]);
    $t->assertSame('entry-2', $direct->post($directEntry), 'ledger post with explicit accounts');
    $t->assertFalse($directConn->calledWith('posting_account'), 'explicit accounts skip role resolution');

    $t->assertSame('reversal-uuid', $ledger->reverse('entry-uuid', '2026-01-03', 'undo', 'rev-key'), 'ledger reverse');
    $t->assertSame('acct-uuid', $ledger->resolveAccount('cash'), 'ledger resolveAccount');

    // ---- ReportingService -------------------------------------------------

    $reportConn = new FakeConnection();
    $reportConn->on('cash_basis_income_statement', static fn (): array => [['account' => 'Revenue', 'amount' => '80.0000']]);
    $reportConn->on('income_statement', static fn (): array => [['account' => 'Revenue', 'amount' => '100.0000']]);
    $reportConn->on('balance_sheet_check', static fn (): array => [['balanced' => true]]);
    $reportConn->on('balance_sheet', static fn (): array => [['account' => 'Cash', 'amount' => '50.0000']]);
    $reportConn->on('net_income', static fn (): string => '42.0000');
    $reportConn->on('v_vendor_balance_realtime', static fn (): array => [['party_id' => 'p1', 'balance' => '10.0000']]);
    $reportConn->on('inventory_item', static fn (): array => [['active_items' => 3, 'units_on_hand' => 9, 'total_value' => '90.0000']]);
    $reportConn->on('FROM sale_line sl', static fn (): array => [['sku' => 'SKU1', 'revenue' => '20.0000']]);
    $reportConn->on('FROM sale_line_tax', static fn (): array => [['jurisdiction' => 'CA', 'tax_collected' => '2.0000']]);
    $reportConn->on('GROUP BY sale_date', static fn (): array => [['sale_date' => '2026-01-02', 'total' => '30.0000']]);
    $reportConn->on('FROM sale', static fn (): array => [['sale_count' => 2, 'total' => '30.0000']]);
    $report = new ReportingService($reportConn);

    $t->assertSame('Revenue', $report->incomeStatement('2026-01-01', '2026-01-31')[0]['account'], 'income statement');
    $t->assertSame('80.0000', $report->cashBasisIncomeStatement('2026-01-01', '2026-01-31')[0]['amount'], 'cash basis income statement');
    $t->assertSame('Cash', $report->balanceSheet('2026-01-31')[0]['account'], 'balance sheet with date');
    $t->assertSame('Cash', $report->balanceSheet()[0]['account'], 'balance sheet defaults to today');
    $t->assertSame('42.0000', $report->netIncome('2026-01-01', '2026-01-31'), 'net income');
    $t->assertSame(true, $report->balanceSheetCheck('2026-01-31')['balanced'], 'balance sheet check with date');
    $t->assertSame(true, $report->balanceSheetCheck()['balanced'], 'balance sheet check defaults to today');
    $t->assertSame(2, $report->salesSummary('2026-01-01', '2026-01-31')['sale_count'], 'sales summary');
    $t->assertSame('2026-01-02', $report->salesByDay('2026-01-01', '2026-01-31')[0]['sale_date'], 'sales by day');
    $t->assertSame('SKU1', $report->topItems('2026-01-01', '2026-01-31')[0]['sku'], 'top items');
    $t->assertSame('p1', $report->vendorBalances()[0]['party_id'], 'vendor balances');
    $t->assertSame('p1', $report->vendorBalance('p1')['party_id'], 'single vendor balance');
    $t->assertSame(3, $report->inventoryValuation()['active_items'], 'inventory valuation');
    $t->assertSame('CA', $report->taxCollected('2026-01-01', '2026-01-31')[0]['jurisdiction'], 'tax collected');

    // A missing vendor returns null rather than throwing.
    $emptyConn = new FakeConnection();
    $t->assertSame(null, (new ReportingService($emptyConn))->vendorBalance('nobody'), 'missing vendor balance is null');
};
