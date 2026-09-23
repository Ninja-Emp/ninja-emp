<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use InvalidArgumentException;
use NinjaEMP\Auth\Role;
use NinjaEMP\Auth\SessionAuth;
use NinjaEMP\Auth\User;
use NinjaEMP\Http\ControllerResolver;
use NinjaEMP\Http\Exception\AccessDeniedException;
use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Http\Exception\TenantNotResolvedException;
use NinjaEMP\Http\Exception\UnauthorizedException;
use NinjaEMP\Http\HttpKernel;
use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Message\ServerRequest;
use NinjaEMP\Http\Message\Uri;
use NinjaEMP\Http\Middleware\AuthMiddleware;
use NinjaEMP\Http\Middleware\RbacMiddleware;
use NinjaEMP\Http\Middleware\TenantMiddleware;
use NinjaEMP\Http\Routing\RouteCollection;
use NinjaEMP\Http\Routing\RouteMatch;
use NinjaEMP\Http\Routing\Router;
use NinjaEMP\Money\Allocator;
use NinjaEMP\Money\Currency;
use NinjaEMP\Money\Money;
use NinjaEMP\Tenancy\InMemoryTenantRegistry;
use NinjaEMP\Tenancy\TenantRecord;
use NinjaEMP\Tenancy\TenantResolver;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\RequestHandlerInterface;
use RuntimeException;

require_once __DIR__ . '/Support/FakeConnection.php';

/** A controller whose action returns a non-PSR-7 value (to exercise the guard). */
final class BadResponseController
{
    /** @param array<string, string> $params */
    public function bad(ServerRequestInterface $request, array $params): string
    {
        return 'not a response';
    }
}

/** A trivial terminal handler that returns a fixed response. */
final class FixedHandler implements RequestHandlerInterface
{
    public function __construct(private readonly ResponseInterface $response)
    {
    }

    public function handle(ServerRequestInterface $request): ResponseInterface
    {
        return $this->response;
    }
}

/**
 * Hardening tests for the HTTP kernel's error branches, the tenant and RBAC
 * middleware, session auth, and the money allocator.
 */
return static function (TestHarness $t): void {
    // ---- HttpKernel error branches ---------------------------------------

    $t->suite('HttpKernel (hardening)');

    $collection = new RouteCollection();
    $collection->add(['GET'], '/ghost', 'NinjaEMP\\Tests\\GhostController', 'index');
    $collection->add(['GET'], '/no-action', BadResponseController::class, 'missingAction');
    $collection->add(['GET'], '/bad-response', BadResponseController::class, 'bad');
    $router = new Router($collection);
    $kernel = new HttpKernel($router, new ControllerResolver());

    $t->assertThrows(
        NotFoundException::class,
        static fn () => $kernel->handle(new ServerRequest('GET', new Uri('http://localhost/ghost'))),
        'a route to a missing controller class is a not-found',
    );
    $t->assertThrows(
        NotFoundException::class,
        static fn () => $kernel->handle(new ServerRequest('GET', new Uri('http://localhost/no-action'))),
        'a route to a missing action is a not-found',
    );
    $t->assertThrows(
        RuntimeException::class,
        static fn () => $kernel->handle(new ServerRequest('GET', new Uri('http://localhost/bad-response'))),
        'a controller returning a non-response is a runtime error',
    );

    // ---- TenantMiddleware -------------------------------------------------

    $t->suite('TenantMiddleware (hardening)');

    $registry = new InMemoryTenantRegistry();
    $registry->add(new TenantRecord('t-1', 'acme', 'tenant_acme', 'Acme Mall'), 'acme.ninjaemp.app');
    $resolver = new TenantResolver($registry);
    $handler = new FixedHandler(new Response(200, 'ok'));

    // Resolved by the X-Tenant header.
    $mw = new TenantMiddleware($resolver);
    $req = new ServerRequest('GET', new Uri('http://localhost/'), [], null, ['X-Tenant' => 'acme']);
    $res = $mw->process($req, $handler);
    $t->assertSame(200, $res->getStatusCode(), 'the header-resolved tenant passes through');

    // Resolved by the tenant query param.
    $req = (new ServerRequest('GET', new Uri('http://localhost/')))->withQueryParams(['tenant' => 'acme']);
    $res = $mw->process($req, $handler);
    $t->assertSame(200, $res->getStatusCode(), 'the query-resolved tenant passes through');

    // Unresolved and required -> throws.
    $t->assertThrows(
        TenantNotResolvedException::class,
        static fn () => $mw->process(new ServerRequest('GET', new Uri('http://unknown.example/')), $handler),
        'an unresolved tenant is rejected when required',
    );

    // Unresolved but not required -> passes through.
    $optional = new TenantMiddleware($resolver, false);
    $res = $optional->process(new ServerRequest('GET', new Uri('http://unknown.example/')), $handler);
    $t->assertSame(200, $res->getStatusCode(), 'an unresolved tenant passes through when optional');

    // ---- RbacMiddleware ---------------------------------------------------

    $t->suite('RbacMiddleware (hardening)');

    $rbac = new RbacMiddleware();
    $publicMatch = new RouteMatch('C', 'a', [], 'n', null, true);
    $openMatch = new RouteMatch('C', 'a', [], 'n', null, false);
    $guardedMatch = new RouteMatch('C', 'a', [], 'n', 'settings.manage', false);

    // No route match at all -> passes.
    $res = $rbac->process(new ServerRequest('GET', new Uri('http://localhost/')), $handler);
    $t->assertSame(200, $res->getStatusCode(), 'no route match passes through');

    // Public route -> passes.
    $req = (new ServerRequest('GET', new Uri('http://localhost/')))->withAttribute('route', $publicMatch);
    $t->assertSame(200, $rbac->process($req, $handler)->getStatusCode(), 'a public route passes through');

    // Route with no permission -> passes.
    $req = (new ServerRequest('GET', new Uri('http://localhost/')))->withAttribute('route', $openMatch);
    $t->assertSame(200, $rbac->process($req, $handler)->getStatusCode(), 'a permission-less route passes through');

    // Guarded route, no user -> 401.
    $req = (new ServerRequest('GET', new Uri('http://localhost/')))->withAttribute('route', $guardedMatch);
    $t->assertThrows(
        UnauthorizedException::class,
        static fn () => $rbac->process($req, $handler),
        'a guarded route without a user is 401',
    );

    // Guarded route, user lacking the permission -> 403.
    $cashier = new User('u-1', 'Dana', Role::of(Role::CASHIER), 't-1');
    $req = (new ServerRequest('GET', new Uri('http://localhost/')))
        ->withAttribute('route', $guardedMatch)
        ->withAttribute('user', $cashier);
    $t->assertThrows(
        AccessDeniedException::class,
        static fn () => $rbac->process($req, $handler),
        'a user lacking the permission is 403',
    );

    // Guarded route, user holding the permission -> passes.
    $owner = new User('u-2', 'Owen', Role::of(Role::OWNER), 't-1');
    $req = (new ServerRequest('GET', new Uri('http://localhost/')))
        ->withAttribute('route', $guardedMatch)
        ->withAttribute('user', $owner);
    $t->assertSame(200, $rbac->process($req, $handler)->getStatusCode(), 'a permitted user passes through');

    // ---- AuthMiddleware ---------------------------------------------------

    $t->suite('AuthMiddleware (hardening)');

    $_SESSION = [];
    $auth = new SessionAuth();
    $authMw = new AuthMiddleware($auth);

    // Anonymous: no user attribute is attached.
    $captured = null;
    $capture = new class ($captured) implements RequestHandlerInterface {
        public function __construct(private mixed &$captured)
        {
        }

        public function handle(ServerRequestInterface $request): ResponseInterface
        {
            $this->captured = $request->getAttribute('user');

            return new Response(200, 'ok');
        }
    };
    $authMw->process(new ServerRequest('GET', new Uri('http://localhost/')), $capture);
    $t->assertSame(null, $captured, 'an anonymous request carries no user');

    $auth->login(new User('u-1', 'Dana', Role::of(Role::CASHIER), 't-1'));
    $authMw->process(new ServerRequest('GET', new Uri('http://localhost/')), $capture);
    $t->assertTrue($captured instanceof User, 'a logged-in request carries the user');
    $t->assertSame('u-1', $captured->id, 'the attached user is the session user');

    // ---- SessionAuth ------------------------------------------------------

    $t->suite('SessionAuth (hardening)');

    $_SESSION = [];
    $session = new SessionAuth();
    $t->assertFalse($session->check(), 'a fresh session is not authenticated');
    $t->assertSame(null, $session->user(), 'a fresh session has no user');
    $t->assertFalse($session->can('pos.use'), 'a fresh session can do nothing');

    $session->login(new User('u-9', 'Nina', Role::of(Role::MANAGER), 't-9'));
    $t->assertTrue($session->check(), 'after login the session is authenticated');
    $user = $session->user();
    $t->assertSame('u-9', $user?->id, 'the session user id round-trips');
    $t->assertSame('Nina', $user?->name, 'the session user name round-trips');
    $t->assertSame('manager', $user?->role->code(), 'the session user role round-trips');
    $t->assertSame('t-9', $user?->tenantId, 'the session user tenant round-trips');
    $t->assertTrue($session->can('reports.view'), 'the manager can view reports');
    $t->assertFalse($session->can('settings.manage'), 'the manager cannot manage settings');

    $session->logout();
    $t->assertFalse($session->check(), 'after logout the session is not authenticated');

    // A session with an unknown role rehydrates to null.
    $_SESSION = ['nem_user' => ['id' => 'u-1', 'name' => 'X', 'role' => 'wizard', 'tenant_id' => 't-1']];
    $t->assertSame(null, (new SessionAuth())->user(), 'an unknown role rehydrates to null');

    // A session missing required keys rehydrates to null.
    $_SESSION = ['nem_user' => ['id' => 'u-1']];
    $t->assertSame(null, (new SessionAuth())->user(), 'a session missing keys rehydrates to null');

    // A custom session key is honoured.
    $_SESSION = [];
    $custom = new SessionAuth('custom_key');
    $custom->login(new User('u-3', 'Cara', Role::of(Role::OWNER), 't-3'));
    $t->assertTrue(isset($_SESSION['custom_key']), 'the custom session key is used');
    $t->assertSame('u-3', $custom->user()?->id, 'the custom-key session rehydrates');

    // ---- Allocator --------------------------------------------------------

    $t->suite('Allocator (hardening)');

    $usd = Currency::usd();

    // An even split of a non-divisible amount sums exactly.
    $parts = Allocator::allocate(Money::of('10.00', $usd), [1, 1, 1]);
    $t->assertSame(['3.3334', '3.3333', '3.3333'], array_map(static fn (Money $m): string => $m->amount(), $parts), 'an even split sums exactly');
    $sum = Money::zero($usd);

    foreach ($parts as $p) {
        $sum = $sum->plus($p);
    }
    $t->assertSame('10.0000', $sum->amount(), 'the parts sum back to the whole');

    // A weighted split (60/40).
    $parts = Allocator::allocate(Money::of('100.00', $usd), ['0.6', '0.4']);
    $t->assertSame(['60.0000', '40.0000'], array_map(static fn (Money $m): string => $m->amount(), $parts), 'a 60/40 split is exact');

    // A negative total allocates symmetrically.
    $parts = Allocator::allocate(Money::of('-10.00', $usd), [1, 1]);
    $t->assertSame(['-5.0000', '-5.0000'], array_map(static fn (Money $m): string => $m->amount(), $parts), 'a negative total splits symmetrically');

    // allocateByRate is the same guarantee.
    $parts = Allocator::allocateByRate(Money::of('1.00', $usd), ['0.5', '0.5']);
    $t->assertSame(['0.5000', '0.5000'], array_map(static fn (Money $m): string => $m->amount(), $parts), 'allocateByRate splits evenly');

    // Tie-break: equal remainders go to the lower index.
    $parts = Allocator::allocate(Money::of('0.0002', $usd), [1, 1, 1]);
    $t->assertSame(['0.0001', '0.0001', '0.0000'], array_map(static fn (Money $m): string => $m->amount(), $parts), 'equal remainders break by index');

    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Allocator::allocate(Money::of('1.00', $usd), []),
        'allocating across zero parts is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Allocator::allocate(Money::of('1.00', $usd), [1, -1]),
        'a negative weight is rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Allocator::allocate(Money::of('1.00', $usd), [0, 0]),
        'weights summing to zero are rejected',
    );
    $t->assertThrows(
        InvalidArgumentException::class,
        static fn () => Allocator::allocate(Money::of('1.00', $usd), ['abc']),
        'a malformed weight is rejected',
    );
};
