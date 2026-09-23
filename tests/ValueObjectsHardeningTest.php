<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use InvalidArgumentException;
use NinjaEMP\Auth\PasswordHasher;
use NinjaEMP\Auth\Role;
use NinjaEMP\Db\ResultSet;
use NinjaEMP\Db\Row;
use NinjaEMP\Db\Sql\Identifier;
use NinjaEMP\Db\Value\Tenant;
use NinjaEMP\Domain\Pos\SaleLineInput;
use NinjaEMP\Domain\Pos\SaleRequest;
use NinjaEMP\Domain\Pos\TenderInput;
use NinjaEMP\Http\ControllerResolver;
use NinjaEMP\Http\Exception\AccessDeniedException;
use NinjaEMP\Http\Exception\HttpException;
use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Http\Exception\UnauthorizedException;
use NinjaEMP\Ledger\JournalLine;
use NinjaEMP\Ledger\Tender;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;
use Psr\Container\ContainerInterface;
use RuntimeException;

require_once __DIR__ . '/Support/FakeConnection.php';

/** A no-argument controller used to exercise ControllerResolver's fallback path. */
final class ResolvableController
{
    public function ping(): string
    {
        return 'pong';
    }
}

/**
 * Hardening tests for the small value objects, exceptions, and helpers that the
 * mutation gate flagged as thinly covered: HTTP exceptions, POS input DTOs, the
 * controller resolver, the password hasher, result sets, roles, ledger lines,
 * currency, SQL identifiers, and the tenant context.
 */
return static function (TestHarness $t): void {
    // ---- HttpException + subclasses --------------------------------------

    $t->suite('HttpException');

    $e = new HttpException(418);
    $t->assertSame(418, $e->statusCode(), 'statusCode returns the code');
    $t->assertSame('An error occurred.', $e->getMessage(), 'an unknown status gets the generic message');
    $t->assertSame(418, $e->getCode(), 'the exception code mirrors the status');

    $t->assertSame('Bad request.', (new HttpException(400))->getMessage(), '400 default message');
    $t->assertSame('Authentication required.', (new HttpException(401))->getMessage(), '401 default message');
    $t->assertSame('You do not have permission to perform this action.', (new HttpException(403))->getMessage(), '403 default message');
    $t->assertSame('Not found.', (new HttpException(404))->getMessage(), '404 default message');
    $t->assertSame('Method not allowed.', (new HttpException(405))->getMessage(), '405 default message');
    $t->assertSame('Conflict.', (new HttpException(409))->getMessage(), '409 default message');
    $t->assertSame('Unprocessable entity.', (new HttpException(422))->getMessage(), '422 default message');
    $t->assertSame('Too many requests.', (new HttpException(429))->getMessage(), '429 default message');

    $custom = new HttpException(400, 'Custom message.');
    $t->assertSame('Custom message.', $custom->getMessage(), 'a custom message overrides the default');

    $prev = new RuntimeException('cause');
    $withPrev = new HttpException(500, '', $prev);
    $t->assertSame($prev, $withPrev->getPrevious(), 'the previous exception is preserved');

    $denied = new AccessDeniedException('inventory.manage');
    $t->assertSame(403, $denied->statusCode(), 'AccessDeniedException is a 403');
    $t->assertSame('inventory.manage', $denied->permission(), 'AccessDeniedException carries the permission');
    $t->assertSame(null, (new AccessDeniedException())->permission(), 'AccessDeniedException permission defaults to null');

    $t->assertSame(404, (new NotFoundException())->statusCode(), 'NotFoundException is a 404');
    $t->assertSame('Not found.', (new NotFoundException())->getMessage(), 'NotFoundException default message');
    $t->assertSame('Gone.', (new NotFoundException('Gone.'))->getMessage(), 'NotFoundException custom message');

    $t->assertSame(401, (new UnauthorizedException())->statusCode(), 'UnauthorizedException is a 401');
    $t->assertSame('Authentication required.', (new UnauthorizedException())->getMessage(), 'UnauthorizedException default message');

    // ---- SaleRequest ------------------------------------------------------

    $t->suite('SaleRequest');

    $line = new SaleLineInput(SaleLineInput::OWNED, 'Widget', inventoryItemId: 'inv-1');
    $tender = new TenderInput('cash', '10.00');

    $req = new SaleRequest([$line], [$tender]);
    $t->assertSame('USD', $req->currency, 'currency defaults to USD');
    $t->assertSame('in_store', $req->channel, 'channel defaults to in_store');
    $t->assertSame(null, $req->registerId, 'registerId defaults to null');
    $t->assertSame(null, $req->idempotencyKey, 'idempotencyKey defaults to null');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new SaleRequest([], [$tender]),
        'a sale with no lines is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new SaleRequest([$line], []),
        'a sale with no tenders is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new SaleRequest([$line], [$tender], channel: 'carrier_pigeon'),
        'an unknown channel is rejected',
    );

    foreach (['in_store', 'online', 'phone', 'event'] as $channel) {
        $ok = new SaleRequest([$line], [$tender], channel: $channel);
        $t->assertSame($channel, $ok->channel, "channel {$channel} is accepted");
    }

    // ---- TenderInput ------------------------------------------------------

    $t->suite('TenderInput');

    $cash = new TenderInput('cash', '12.34');
    $t->assertFalse($cash->isLiability(), 'cash is not a liability tender');
    $t->assertSame(null, $cash->partyId, 'cash carries no party');

    $credit = new TenderInput('store_credit', '5.00', 'party-1');
    $t->assertTrue($credit->isLiability(), 'store credit is a liability tender');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new TenderInput('cash', ''),
        'an empty tender amount is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new TenderInput('cash', '1.2.3'),
        'a malformed tender amount is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new TenderInput('store_credit', '5.00'),
        'a liability tender without a party is rejected',
    );

    // ---- SaleLineInput ----------------------------------------------------

    $t->suite('SaleLineInput');

    $owned = new SaleLineInput(SaleLineInput::OWNED, 'Widget', inventoryItemId: 'inv-1');
    $t->assertFalse($owned->isConsignment(), 'an owned line is not consignment');
    $t->assertSame('1', $owned->quantity, 'quantity defaults to 1');
    $t->assertTrue($owned->isTaxable, 'lines are taxable by default');

    $consigned = new SaleLineInput(SaleLineInput::CONSIGNMENT, 'Vase', commissionRate: '0.40', consignorPartyId: 'c1');
    $t->assertTrue($consigned->isConsignment(), 'a consignment line is consignment');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new SaleLineInput('rental', 'Thing'),
        'an unknown line kind is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new SaleLineInput(SaleLineInput::CONSIGNMENT, 'Vase', commissionRate: '0.40'),
        'a consignment line without a consignor is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new SaleLineInput(SaleLineInput::CONSIGNMENT, 'Vase', consignorPartyId: 'c1'),
        'a consignment line without a commission rate is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => new SaleLineInput(SaleLineInput::OWNED, 'Widget'),
        'an owned line without an inventory item is rejected',
    );

    // ---- ControllerResolver ----------------------------------------------

    $t->suite('ControllerResolver');

    $container = new class implements ContainerInterface {
        /** @var array<string, object> */
        public array $items = [];

        public function get(string $id): mixed
        {
            return $this->items[$id];
        }

        public function has(string $id): bool
        {
            return isset($this->items[$id]);
        }
    };

    $controller = new class {
        public function ping(): string
        {
            return 'pong';
        }
    };
    $container->items['NinjaEMP\\Tests\\FakeController'] = $controller;

    $resolver = new ControllerResolver($container);
    $t->assertSame($controller, $resolver->resolve('NinjaEMP\\Tests\\FakeController'), 'the container is asked first');

    // A container that has the id but returns a non-object falls through to instantiation.
    $badContainer = new class implements ContainerInterface {
        public function get(string $id): mixed
        {
            return 'not-an-object';
        }

        public function has(string $id): bool
        {
            return true;
        }
    };
    $t->assertThrows(
        NotFoundException::class,
        static fn () => (new ControllerResolver($badContainer))->resolve('NinjaEMP\\Tests\\DoesNotExist'),
        'a non-object container hit falls through to a not-found',
    );

    // No container: a real class is instantiated.
    $t->assertTrue(
        (new ControllerResolver())->resolve(ResolvableController::class) instanceof ResolvableController,
        'without a container the class is instantiated directly',
    );

    $t->assertThrows(
        NotFoundException::class,
        static fn () => (new ControllerResolver())->resolve('NinjaEMP\\Tests\\NoSuchController'),
        'an unknown controller class is a not-found',
    );

    // ---- PasswordHasher ---------------------------------------------------

    $t->suite('PasswordHasher');

    $hasher = new PasswordHasher();
    $hash = $hasher->hash('correct horse battery staple');
    $t->assertTrue($hash !== '', 'hash produces a non-empty string');
    $t->assertTrue($hasher->verify('correct horse battery staple', $hash), 'verify accepts the right password');
    $t->assertFalse($hasher->verify('wrong', $hash), 'verify rejects the wrong password');
    $t->assertFalse($hasher->needsRehash($hash), 'a fresh hash does not need rehashing');

    // ---- ResultSet --------------------------------------------------------

    $t->suite('ResultSet');

    $empty = new ResultSet([]);
    $t->assertTrue($empty->isEmpty(), 'an empty result set is empty');
    $t->assertSame(0, $empty->count(), 'an empty result set counts zero');
    $t->assertSame(null, $empty->first(), 'an empty result set has no first row');

    $rows = new ResultSet([new Row(['a' => 1]), new Row(['a' => 2])]);
    $t->assertFalse($rows->isEmpty(), 'a populated result set is not empty');
    $t->assertSame(2, $rows->count(), 'count returns the row count');
    $t->assertSame(1, $rows->first()->get('a'), 'first returns the first row');
    $t->assertSame([['a' => 1], ['a' => 2]], $rows->toArray(), 'toArray maps every row');
    $t->assertSame(2, \count($rows->rows()), 'rows returns the raw list');

    $seen = [];
    foreach ($rows as $row) {
        $seen[] = $row->get('a');
    }
    $t->assertSame([1, 2], $seen, 'the result set is iterable');

    // ---- Role -------------------------------------------------------------

    $t->suite('Role');

    $owner = Role::of(Role::OWNER);
    $t->assertSame('owner', $owner->code(), 'code returns the role code');
    $t->assertSame('Owner', $owner->label(), 'label returns the display label');
    $t->assertTrue($owner->can('settings.manage'), 'the owner can manage settings');
    $t->assertFalse($owner->can('nonexistent.permission'), 'an unknown permission is denied');
    $t->assertTrue(\in_array('accounting.view', $owner->permissions(), true), 'the owner has accounting.view');

    $cashier = Role::of(Role::CASHIER);
    $t->assertTrue($cashier->can('pos.use'), 'the cashier can use the POS');
    $t->assertFalse($cashier->can('settings.manage'), 'the cashier cannot manage settings');

    $t->assertTrue(Role::isValid('manager'), 'manager is a valid role');
    $t->assertFalse(Role::isValid('wizard'), 'wizard is not a valid role');
    $t->assertSame(
        ['owner' => 'Owner', 'manager' => 'Manager', 'accountant' => 'Accountant', 'cashier' => 'Cashier'],
        Role::all(),
        'all() returns the full label map',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Role::of('wizard'),
        'an unknown role is rejected',
    );

    // ---- Tender -----------------------------------------------------------

    $t->suite('Tender');

    $usd = Currency::usd();
    $cashTender = Tender::of(Tender::CASH, Money::of('10.00', $usd));
    $t->assertSame('undeposited_funds', $cashTender->debitRole(), 'cash debits undeposited funds');
    $t->assertSame(null, $cashTender->subledgerTypeCode(), 'cash has no subledger');

    $cardTender = Tender::of(Tender::CARD, Money::of('10.00', $usd));
    $t->assertSame('card_clearing', $cardTender->debitRole(), 'card debits card clearing');

    $giftTender = Tender::of(Tender::GIFT_CERT, Money::of('10.00', $usd), 'party-1');
    $t->assertSame('gift_certificate_control', $giftTender->debitRole(), 'gift cert debits the control account');
    $t->assertSame('gift_certificate', $giftTender->subledgerTypeCode(), 'gift cert is subledger-tagged');

    $line = $giftTender->toJournalLine();
    $t->assertSame('gift_certificate_control', $line->accountRole, 'the journal line carries the debit role');
    $t->assertSame('party-1', $line->partyId, 'the journal line carries the party');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Tender::of(Tender::GIFT_CERT, Money::of('10.00', $usd))->toJournalLine(),
        'a liability tender without a party cannot build a journal line',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Tender::of('bitcoin', Money::of('10.00', $usd)),
        'an unknown tender type is rejected',
    );
    $t->assertSame(
        ['cash', 'check', 'card', 'gift_cert', 'store_credit', 'vendor_draw'],
        Tender::codes(),
        'codes() lists every tender type',
    );

    // ---- JournalLine ------------------------------------------------------

    $t->suite('JournalLine');

    $debit = JournalLine::debit('undeposited_funds', Money::of('10.00', $usd));
    $t->assertSame('10.0000', $debit->debit->amount(), 'a debit line carries the debit amount');
    $t->assertSame('0.0000', $debit->credit->amount(), 'a debit line has a zero credit');

    $credit = JournalLine::credit('sales_revenue', Money::of('10.00', $usd));
    $t->assertSame('10.0000', $credit->credit->amount(), 'a credit line carries the credit amount');

    $debitAcct = JournalLine::debitAccount('11111111-1111-1111-1111-111111111111', Money::of('10.00', $usd));
    $t->assertSame('11111111-1111-1111-1111-111111111111', $debitAcct->accountId, 'a debitAccount line carries the account id');
    $t->assertSame(null, $debitAcct->accountRole, 'a debitAccount line has no role');

    $creditAcct = JournalLine::creditAccount('11111111-1111-1111-1111-111111111111', Money::of('10.00', $usd));
    $t->assertSame('10.0000', $creditAcct->credit->amount(), 'a creditAccount line carries the credit');

    $tagged = JournalLine::debit('customer_credit_control', Money::of('10.00', $usd), 'party-1', 'customer_credit', 'memo');
    $arr = $tagged->toArray('22222222-2222-2222-2222-222222222222');
    $t->assertSame('22222222-2222-2222-2222-222222222222', $arr['account_id'], 'toArray uses the resolved account id');
    $t->assertSame('10.0000', $arr['debit'], 'toArray carries the debit');
    $t->assertSame('USD', $arr['currency'], 'toArray carries the currency');
    $t->assertSame('party-1', $arr['party_id'], 'toArray carries the party');
    $t->assertSame('customer_credit', $arr['subledger_type_code'], 'toArray carries the subledger type');
    $t->assertSame('memo', $arr['memo'], 'toArray carries the memo');

    $plain = JournalLine::debit('undeposited_funds', Money::of('10.00', $usd))->toArray('33333333-3333-3333-3333-333333333333');
    $t->assertFalse(\array_key_exists('party_id', $plain), 'an untagged line omits the party');
    $t->assertFalse(\array_key_exists('memo', $plain), 'a memo-less line omits the memo');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => JournalLine::debit('undeposited_funds', Money::of('-1.00', $usd)),
        'a negative journal amount is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => JournalLine::debit('undeposited_funds', Money::of('0.00', $usd)),
        'a zero journal amount is rejected (neither debit nor credit)',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => JournalLine::debit('undeposited_funds', Money::of('10.00', $usd), 'party-1'),
        'a party without a subledger type is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => JournalLine::debit('undeposited_funds', Money::of('10.00', $usd), null, 'customer_credit'),
        'a subledger type without a party is rejected',
    );

    // ---- Currency ---------------------------------------------------------

    $t->suite('Currency');

    $t->assertSame('USD', Currency::of('usd')->code(), 'currency codes are normalised to uppercase');
    $t->assertSame('EUR', Currency::of('  eur  ')->code(), 'currency codes are trimmed');
    $t->assertSame('USD', Currency::usd()->code(), 'usd() returns USD');
    $t->assertTrue(Currency::of('USD')->isKnown(), 'USD is a known currency');
    $t->assertFalse(Currency::of('XYZ')->isKnown(), 'XYZ is not a known currency');
    $t->assertSame('US Dollar', Currency::of('USD')->name(), 'a known currency has a display name');
    $t->assertSame('XYZ', Currency::of('XYZ')->name(), 'an unknown currency falls back to its code');
    $t->assertTrue(Currency::of('USD')->equals(Currency::of('usd')), 'equal codes are equal');
    $t->assertFalse(Currency::of('USD')->equals(Currency::of('EUR')), 'different codes are not equal');
    $t->assertSame('USD', (string) Currency::of('USD'), 'a currency stringifies to its code');
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Currency::of('US'),
        'a two-letter currency code is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Currency::of('US1'),
        'a non-alpha currency code is rejected',
    );

    // ---- Identifier -------------------------------------------------------

    $t->suite('Identifier');

    $id = Identifier::of('tenant_acme');
    $t->assertSame('tenant_acme', $id->name(), 'name returns the identifier');
    $t->assertSame('"tenant_acme"', $id->quoted(), 'quoted double-quotes the identifier');
    $t->assertSame('"tenant_acme"', (string) $id, 'an identifier stringifies to its quoted form');
    $t->assertTrue(Identifier::isValid('a1_b2'), 'a valid identifier is valid');
    $t->assertFalse(Identifier::isValid('1abc'), 'an identifier cannot start with a digit');
    $t->assertFalse(Identifier::isValid('has space'), 'an identifier cannot contain a space');
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Identifier::of('DROP TABLE'),
        'an unsafe identifier is rejected',
    );

    // ---- Tenant (Db\Value) ------------------------------------------------

    $t->suite('Tenant');

    $tenant = Tenant::of('tenant-1', 'tenant_acme', 'actor-1');
    $t->assertSame('tenant-1', $tenant->tenantId(), 'tenantId returns the id');
    $t->assertSame('actor-1', $tenant->actorId(), 'actorId returns the actor');
    $t->assertSame('tenant_acme', $tenant->schema(), 'schema returns the schema');

    $noActor = Tenant::of('tenant-1', 'tenant_acme');
    $t->assertSame(null, $noActor->actorId(), 'actorId defaults to null');

    $withActor = $noActor->withActor('actor-2');
    $t->assertSame('actor-2', $withActor->actorId(), 'withActor sets the actor');
    $t->assertSame('tenant-1', $withActor->tenantId(), 'withActor preserves the tenant id');
    $t->assertSame('tenant_acme', $withActor->schema(), 'withActor preserves the schema');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Tenant::of('tenant-1', 'bad schema'),
        'an unsafe schema name is rejected',
    );
};
