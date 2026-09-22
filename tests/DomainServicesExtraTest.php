<?php

declare(strict_types=1);

use NinjaEMP\Auth\PasswordHasher;
use NinjaEMP\Auth\Role;
use NinjaEMP\Db\ResultSet;
use NinjaEMP\Db\Row;
use NinjaEMP\Db\Sql\Identifier;
use NinjaEMP\Domain\Consignment\ConsignmentService;
use NinjaEMP\Domain\Inventory\InventoryService;
use NinjaEMP\Domain\Pos\PosService;
use NinjaEMP\Domain\Pos\SaleLineInput;
use NinjaEMP\Domain\Pos\SaleRequest;
use NinjaEMP\Domain\Pos\TenderInput;
use NinjaEMP\Domain\StoredValue\StoredValueService;
use NinjaEMP\Http\ControllerResolver;
use NinjaEMP\Http\Exception\AccessDeniedException;
use NinjaEMP\Http\Exception\HttpException;
use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Money\Currency;
use NinjaEMP\Tests\Support\FakeConnection;
use NinjaEMP\Tests\TestHarness;
use Psr\Container\ContainerInterface;

require_once __DIR__ . '/Support/FakeConnection.php';

return static function (TestHarness $t): void {
    // ---- ConsignmentService (extended) -----------------------------------

    $t->suite('ConsignmentService (extended)');

    $conn = new FakeConnection();
    $conn->on('INSERT INTO consignment_item', static fn (): array => [['id' => 'ci-2']]);
    $conn->on('SELECT agreed_price FROM consignment_item', static fn (): array => [['agreed_price' => '10.0000']]);
    $conn->on('INSERT INTO item_price_change', static fn () => null);
    $conn->on('UPDATE consignment_item SET agreed_price', static fn () => null);
    $conn->on('FROM consignment_sale_line csl', static fn (): array => [
        ['id' => 'csl-1', 'sale_price' => '100.0000', 'commission_amount' => '40.0000', 'net_to_consignor' => '60.0000'],
        ['id' => 'csl-2', 'sale_price' => '50.0000', 'commission_amount' => '20.0000', 'net_to_consignor' => '30.0000'],
    ]);
    $conn->on('INSERT INTO consignor_settlement', static fn (): array => [['id' => 'set-1']]);
    $conn->on('INSERT INTO settlement_line', static fn () => null);
    $conn->on('INSERT INTO consignor_payout', static fn (): array => [['id' => 'payout-1']]);
    $conn->on('post_consignor_payout', static fn (): string => 'payout-entry');

    $cons = new ConsignmentService($conn);
    $t->assertSame('ci-2', $cons->receiveItem('agr-1', 'Lamp', '25.00'), 'receiveItem returns the item id');

    $cons->changePrice('ci-2', '30.00', 'market');
    $t->assertTrue($conn->calledWith('INSERT INTO item_price_change'), 'changePrice records history');
    $t->assertTrue($conn->calledWith('UPDATE consignment_item SET agreed_price'), 'changePrice updates the item');

    $settlement = $cons->settleAndPay('consignor-1', '2026-01-01', '2026-01-31');
    $t->assertSame('set-1', $settlement['settlementId'], 'settleAndPay returns the settlement id');
    $t->assertSame('payout-1', $settlement['payoutId'], 'settleAndPay returns the payout id');
    $t->assertSame('payout-entry', $settlement['journalEntryId'], 'settleAndPay posts the payout');
    $t->assertSame('90.0000', $settlement['netPayable'], 'settleAndPay sums net payable');

    // No sold lines in the period.
    $emptyCons = new ConsignmentService(new FakeConnection());
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $emptyCons->settleAndPay('consignor-1', '2026-01-01', '2026-01-31'),
        'settleAndPay rejects an empty period',
    );

    // Unknown payout method.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $cons->settleAndPay('consignor-1', '2026-01-01', '2026-01-31', 'USD', 'bitcoin'),
        'settleAndPay rejects an unknown method',
    );

    // Unknown settlement frequency.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $cons->createAgreement('consignor-1', '0.40', 'hourly'),
        'createAgreement rejects an unknown frequency',
    );

    // Unknown consignment channel.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $cons->recordSale([['itemId' => 'ci-1', 'consignorPartyId' => 'c1', 'salePrice' => '1', 'commissionRate' => '0.4']], 'USD', null, 'carrier-pigeon'),
        'recordSale rejects an unknown channel',
    );

    // changePrice on a missing item.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new ConsignmentService(new FakeConnection()))->changePrice('nope', '1.00'),
        'changePrice rejects a missing item',
    );

    // A settlement whose net is not positive cannot be paid.
    $zeroConn = new FakeConnection();
    $zeroConn->on('FROM consignment_sale_line csl', static fn (): array => [
        ['id' => 'csl-1', 'sale_price' => '10.0000', 'commission_amount' => '10.0000', 'net_to_consignor' => '0.0000'],
    ]);
    $zeroConn->on('INSERT INTO consignor_settlement', static fn (): array => [['id' => 'set-0']]);
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new ConsignmentService($zeroConn))->settleAndPay('consignor-1', '2026-01-01', '2026-01-31'),
        'settleAndPay rejects a non-positive net',
    );

    // ---- PosService (extended) -------------------------------------------

    $t->suite('PosService (extended)');

    $posConn = new FakeConnection();
    $posConn->on('INSERT INTO sale_line', static fn () => null);
    $posConn->on('INSERT INTO sale', static fn (): array => [['id' => 'sale-9', 'sale_no' => '9001']]);
    $posConn->on('INSERT INTO payment_tender', static fn () => null);
    $posConn->on('INSERT INTO payment', static fn (): array => [['id' => 'pay-9']]);
    $posConn->on('post_sale_inventory', static fn (): int => 1);
    $posConn->on('post_sale(', static fn (): string => 'entry-9');
    $posConn->on('post_refund_inventory', static fn (): int => 1);
    $posConn->on('post_refund(', static fn (): string => 'refund-entry');
    $posConn->on('INSERT INTO shift', static fn (): array => [['id' => 'shift-9']]);
    $posConn->on('post_shift_close', static fn (): string => 'close-entry');
    $posConn->on('INSERT INTO merchant_settlement', static fn (): array => [['id' => 'ms-1']]);
    $posConn->on('post_merchant_settlement', static fn (): string => 'ms-entry');

    $pos = new PosService($posConn);

    // A sale with a discount, tax, and a consignment line, no explicit key.
    $result = $pos->ringUp(new SaleRequest(
        lines: [
            new SaleLineInput(
                kind: SaleLineInput::CONSIGNMENT,
                description: 'Vase',
                quantity: '1',
                unitPrice: '100.00',
                discountAmount: '10.00',
                commissionRate: '0.40',
                consignorPartyId: 'consignor-1',
                taxAmount: '7.20',
            ),
        ],
        tenders: [new TenderInput('cash', '97.20')],
    ));
    $t->assertSame('100.0000', $result->subtotal, 'extended: subtotal is gross');
    $t->assertSame('10.0000', $result->discountTotal, 'extended: discount total');
    $t->assertSame('7.2000', $result->taxTotal, 'extended: tax total');
    $t->assertSame('97.2000', $result->total, 'extended: total = subtotal - discount + tax');
    $postCall = $posConn->findCall('post_sale(');
    $t->assertTrue(str_starts_with($postCall['params']['key'], 'pos_sale:'), 'derived idempotency key is stable');

    // A discount larger than the extended price is refused.
    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => $pos->ringUp(new SaleRequest(
            lines: [new SaleLineInput(SaleLineInput::OWNED, 'Widget', '1', '5.00', '9.00', inventoryItemId: 'inv-1')],
            tenders: [new TenderInput('cash', '0.00')],
        )),
        'a discount exceeding the extended price is rejected',
    );

    // Refund: its own document that reverses the original.
    $refund = $pos->refund('sale-9', [
        new SaleLineInput(SaleLineInput::OWNED, 'Widget', '1', '20.00', inventoryItemId: 'inv-1'),
    ], [new TenderInput('cash', '20.00')]);
    $t->assertSame('refund-entry', $refund->journalEntryId, 'refund posts via post_refund');
    $t->assertSame('20.0000', $refund->total, 'refund total');
    $t->assertTrue($posConn->calledWith('post_refund_inventory'), 'refund restocks inventory');

    // Refund of a consignment line computes the commission split.
    $consRefund = $pos->refund('sale-9', [
        new SaleLineInput(SaleLineInput::CONSIGNMENT, 'Vase', '1', '50.00', commissionRate: '0.40', consignorPartyId: 'c1'),
    ], [new TenderInput('cash', '50.00')]);
    $t->assertSame('50.0000', $consRefund->total, 'consignment refund total');

    // Shift open/close.
    $t->assertSame('shift-9', $pos->openShift('reg-1', '100.00'), 'openShift returns the shift id');
    $t->assertSame('close-entry', $pos->closeShift('shift-9', '120.00'), 'closeShift returns the over/short entry');

    // A balanced drawer returns null.
    $balancedConn = new FakeConnection();
    $balancedConn->on('post_shift_close', static fn () => null);
    $t->assertSame(null, (new PosService($balancedConn))->closeShift('shift-9', '100.00'), 'balanced drawer returns null');

    // Merchant settlement.
    $t->assertSame('ms-entry', $pos->settleMerchant('100.00', '2.50', 'USD', 'ref-1'), 'settleMerchant posts the settlement');
    $msCall = $posConn->findCall('INSERT INTO merchant_settlement');
    $t->assertSame('97.5000', $msCall['params']['net'], 'merchant settlement net = gross - fee');

    // ---- InventoryService (extended) -------------------------------------

    $t->suite('InventoryService (extended)');

    $invConn = new FakeConnection();
    $invConn->on('SELECT on_hand, avg_cost, currency FROM inventory_item', static fn (): array => [
        ['on_hand' => '5', 'avg_cost' => '2.0000', 'currency' => 'USD'],
    ]);
    $invConn->on('COALESCE(sum(on_hand * avg_cost)', static fn (): string => '10.0000');
    $inv = new InventoryService($invConn);

    $position = $inv->position('inv-1');
    $t->assertSame('5', $position['on_hand'], 'position on_hand');
    $t->assertSame('2.0000', $position['avg_cost'], 'position avg_cost');
    $t->assertSame('USD', $position['currency'], 'position currency');
    $t->assertSame('10.0000', $inv->totalValue(), 'totalValue sums on_hand * avg_cost');

    $t->assertThrows(
        InvalidArgumentException::class,
        fn () => (new InventoryService(new FakeConnection()))->position('missing'),
        'position rejects a missing item',
    );

    // ---- StoredValueService ----------------------------------------------

    $t->suite('StoredValueService');

    $svConn = new FakeConnection();
    $svConn->on('issue_stored_value', static fn (): string => 'sv-1');
    $svConn->on('redeem_stored_value', static fn (): string => 'redeem-entry');
    $svConn->on('recognize_breakage', static fn (): string => 'breakage-entry');
    // Register the specific handlers first: both the outstanding() and
    // controlCheck() statements contain the substring "FROM stored_value",
    // so the generic find() handler must be registered last.
    $svConn->on('stored_value_control_check', static fn (): array => [['kind' => 'gift_certificate', 'difference' => '0.0000']]);
    $svConn->on('COALESCE(sum(balance)', static fn (): string => '25.0000');
    $svConn->on('FROM stored_value', static fn (): array => [['id' => 'sv-1', 'code' => 'GC-1', 'balance' => '25.0000']]);
    $sv = new StoredValueService($svConn);

    $t->assertSame('sv-1', $sv->issue(StoredValueService::GIFT_CERTIFICATE, 'GC-1', '25.00'), 'issue returns the id');
    $t->assertSame('redeem-entry', $sv->redeem('GC-1', '10.00', null, 'sale-1'), 'redeem returns the entry id');
    $t->assertSame('breakage-entry', $sv->recognizeBreakage('2026-01-31'), 'recognizeBreakage returns the entry id');
    $t->assertSame('sv-1', $sv->find('GC-1')['id'], 'find returns the instrument');
    $t->assertSame('25.0000', $sv->outstanding(StoredValueService::GIFT_CERTIFICATE), 'outstanding sums balances');
    $t->assertSame('gift_certificate', $sv->controlCheck()[0]['kind'], 'controlCheck returns rows');

    // Breakage returns null when the tenant has not opted in.
    $noBreakage = new FakeConnection();
    $noBreakage->on('recognize_breakage', static fn () => null);
    $t->assertSame(null, (new StoredValueService($noBreakage))->recognizeBreakage(), 'breakage is opt-in');

    // find returns null for an unknown code.
    $t->assertSame(null, (new StoredValueService(new FakeConnection()))->find('nope'), 'find returns null when absent');

    // Validation.
    $t->assertThrows(InvalidArgumentException::class, fn () => $sv->issue('coupon', 'X', '1.00'), 'issue rejects an unknown kind');
    $t->assertThrows(InvalidArgumentException::class, fn () => $sv->issue(StoredValueService::GIFT_CERTIFICATE, '  ', '1.00'), 'issue requires a code');
    $t->assertThrows(InvalidArgumentException::class, fn () => $sv->issue(StoredValueService::GIFT_CERTIFICATE, 'X', '0.00'), 'issue requires a positive amount');
    $t->assertThrows(InvalidArgumentException::class, fn () => $sv->redeem('GC-1', '1.00'), 'redeem requires a GL link');

    // ---- Small value objects ---------------------------------------------

    $t->suite('ValueObjects');

    // SaleRequest
    $req = new SaleRequest([new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '1.00', inventoryItemId: 'i')], [new TenderInput('cash', '1.00')]);
    $t->assertSame('USD', $req->currency, 'SaleRequest default currency');
    $t->assertThrows(InvalidArgumentException::class, fn () => new SaleRequest([], [new TenderInput('cash', '1.00')]), 'SaleRequest needs a line');
    $t->assertThrows(InvalidArgumentException::class, fn () => new SaleRequest([new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '1.00', inventoryItemId: 'i')], []), 'SaleRequest needs a tender');
    $t->assertThrows(InvalidArgumentException::class, fn () => new SaleRequest([new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '1.00', inventoryItemId: 'i')], [new TenderInput('cash', '1.00')], 'USD', null, null, null, 'telepathy'), 'SaleRequest rejects an unknown channel');

    // TenderInput
    $t->assertFalse((new TenderInput('cash', '1.00'))->isLiability(), 'cash is not a liability');
    $t->assertTrue((new TenderInput('store_credit', '1.00', 'p1'))->isLiability(), 'store credit is a liability');
    $t->assertThrows(InvalidArgumentException::class, fn () => new TenderInput('cash', 'abc'), 'TenderInput rejects a malformed amount');

    // SaleLineInput
    $t->assertTrue((new SaleLineInput(SaleLineInput::CONSIGNMENT, 'V', '1', '1.00', commissionRate: '0.4', consignorPartyId: 'c'))->isConsignment(), 'consignment line');
    $t->assertFalse((new SaleLineInput(SaleLineInput::OWNED, 'W', '1', '1.00', inventoryItemId: 'i'))->isConsignment(), 'owned line');
    $t->assertThrows(InvalidArgumentException::class, fn () => new SaleLineInput('rental', 'X'), 'SaleLineInput rejects an unknown kind');
    $t->assertThrows(InvalidArgumentException::class, fn () => new SaleLineInput(SaleLineInput::CONSIGNMENT, 'V', '1', '1.00', commissionRate: '0.4'), 'consignment needs a consignor');
    $t->assertThrows(InvalidArgumentException::class, fn () => new SaleLineInput(SaleLineInput::CONSIGNMENT, 'V', '1', '1.00', consignorPartyId: 'c'), 'consignment needs a rate');
    $t->assertThrows(InvalidArgumentException::class, fn () => new SaleLineInput(SaleLineInput::OWNED, 'W'), 'owned needs an inventory item');

    // Role
    $owner = Role::of(Role::OWNER);
    $t->assertSame('owner', $owner->code(), 'role code');
    $t->assertSame('Owner', $owner->label(), 'role label');
    $t->assertTrue($owner->can('settings.manage'), 'owner can manage settings');
    $t->assertFalse(Role::of(Role::CASHIER)->can('settings.manage'), 'cashier cannot manage settings');
    $t->assertTrue(Role::isValid('manager'), 'manager is valid');
    $t->assertFalse(Role::isValid('wizard'), 'wizard is not valid');
    $t->assertTrue(in_array('pos.use', Role::of(Role::CASHIER)->permissions(), true), 'cashier permissions include pos.use');
    $t->assertSame('Owner', Role::all()['owner'], 'all() maps codes to labels');
    $t->assertThrows(InvalidArgumentException::class, fn () => Role::of('wizard'), 'unknown role rejected');

    // PasswordHasher
    $hasher = new PasswordHasher();
    $hash = $hasher->hash('correct horse battery staple');
    $t->assertTrue($hasher->verify('correct horse battery staple', $hash), 'password verifies');
    $t->assertFalse($hasher->verify('wrong', $hash), 'wrong password fails');
    $t->assertFalse($hasher->needsRehash($hash), 'fresh hash needs no rehash');

    // ControllerResolver
    $resolver = new ControllerResolver();
    $t->assertTrue($resolver->resolve(ArrayObject::class) instanceof ArrayObject, 'resolver instantiates a class');
    $t->assertThrows(NotFoundException::class, fn () => $resolver->resolve('No\\Such\\Controller'), 'resolver rejects a missing class');

    $container = new class () implements ContainerInterface {
        /** @var array<string, object> */
        private array $entries = [];

        public function __construct()
        {
            $this->entries[ArrayObject::class] = new ArrayObject(['from' => 'container']);
        }

        public function get(string $id): mixed
        {
            return $this->entries[$id];
        }

        public function has(string $id): bool
        {
            return isset($this->entries[$id]);
        }
    };
    $fromContainer = (new ControllerResolver($container))->resolve(ArrayObject::class);
    $t->assertSame('container', $fromContainer['from'], 'resolver prefers the container');

    // HttpException
    $t->assertSame(404, (new HttpException(404))->statusCode(), 'http exception status');
    $t->assertSame('Not found.', (new HttpException(404))->getMessage(), 'http exception default message');
    $t->assertSame('Custom.', (new HttpException(500, 'Custom.'))->getMessage(), 'http exception custom message');
    $t->assertSame('Bad request.', (new HttpException(400))->getMessage(), '400 default message');
    $t->assertSame('Authentication required.', (new HttpException(401))->getMessage(), '401 default message');
    $t->assertSame('You do not have permission to perform this action.', (new HttpException(403))->getMessage(), '403 default message');
    $t->assertSame('Method not allowed.', (new HttpException(405))->getMessage(), '405 default message');
    $t->assertSame('Conflict.', (new HttpException(409))->getMessage(), '409 default message');
    $t->assertSame('Unprocessable entity.', (new HttpException(422))->getMessage(), '422 default message');
    $t->assertSame('Too many requests.', (new HttpException(429))->getMessage(), '429 default message');
    $t->assertSame('An error occurred.', (new HttpException(599))->getMessage(), 'unknown status default message');

    $denied = new AccessDeniedException('settings.manage');
    $t->assertSame(403, $denied->statusCode(), 'access denied is 403');
    $t->assertSame('settings.manage', $denied->permission(), 'access denied carries the permission');

    // ResultSet
    $set = new ResultSet([new Row(['a' => 1]), new Row(['a' => 2])]);
    $t->assertSame(2, count($set), 'result set count');
    $t->assertSame([['a' => 1], ['a' => 2]], $set->toArray(), 'result set toArray');
    $t->assertSame(1, $set->first()?->get('a'), 'result set first');
    $t->assertFalse($set->isEmpty(), 'result set not empty');
    $t->assertTrue((new ResultSet([]))->isEmpty(), 'empty result set');
    $t->assertSame(null, (new ResultSet([]))->first(), 'empty result set has no first');
    $t->assertSame(2, count($set->rows()), 'result set rows');
    $iterated = [];

    foreach ($set as $row) {
        $iterated[] = $row->get('a');
    }
    $t->assertSame([1, 2], $iterated, 'result set iterates');

    // Currency
    $t->assertSame('USD', Currency::usd()->code(), 'usd code');
    $t->assertSame('EUR', Currency::of('eur')->code(), 'currency normalises case');
    $t->assertSame('Euro', Currency::of('EUR')->name(), 'known currency name');
    $t->assertSame('XYZ', Currency::of('XYZ')->name(), 'unknown currency falls back to code');
    $t->assertTrue(Currency::of('USD')->equals(Currency::usd()), 'currency equality');
    $t->assertFalse(Currency::of('USD')->equals(Currency::of('EUR')), 'currency inequality');
    $t->assertSame('GBP', (string) Currency::of('GBP'), 'currency stringifies');
    $t->assertThrows(InvalidArgumentException::class, fn () => Currency::of('US'), 'short currency code rejected');

    // Identifier
    $t->assertSame('tenant_demo', Identifier::of('tenant_demo')->name(), 'identifier name');
    $t->assertSame('"tenant_demo"', Identifier::of('tenant_demo')->quoted(), 'identifier quoted');
    $t->assertSame('"tenant_demo"', (string) Identifier::of('tenant_demo'), 'identifier stringifies to quoted');
    $t->assertTrue(Identifier::isValid('a1_b2'), 'valid identifier');
    $t->assertFalse(Identifier::isValid('1bad'), 'identifier cannot start with a digit');
    $t->assertFalse(Identifier::isValid('bad-name'), 'identifier cannot contain a dash');
    $t->assertThrows(InvalidArgumentException::class, fn () => Identifier::of('bad name'), 'unsafe identifier rejected');
};
