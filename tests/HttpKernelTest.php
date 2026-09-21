<?php

declare(strict_types=1);

use NinjaEMP\Auth\Csrf;
use NinjaEMP\Auth\Role;
use NinjaEMP\Auth\SessionAuth;
use NinjaEMP\Auth\User;
use NinjaEMP\Http\ErrorRenderer;
use NinjaEMP\Http\HttpKernel;
use NinjaEMP\Http\ControllerResolver;
use NinjaEMP\Http\Exception\AccessDeniedException;
use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Http\Exception\TenantNotResolvedException;
use NinjaEMP\Http\Exception\UnauthorizedException;
use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Message\ServerRequest;
use NinjaEMP\Http\Message\Stream;
use NinjaEMP\Http\Message\Uri;
use NinjaEMP\Http\Middleware\AuthMiddleware;
use NinjaEMP\Http\Middleware\CsrfMiddleware;
use NinjaEMP\Http\Middleware\ErrorHandlerMiddleware;
use NinjaEMP\Http\Middleware\RbacMiddleware;
use NinjaEMP\Http\Middleware\TenantMiddleware;
use NinjaEMP\Http\Routing\RouteCollection;
use NinjaEMP\Http\Routing\Router;
use NinjaEMP\Tenancy\InMemoryTenantRegistry;
use NinjaEMP\Tenancy\TenantRecord;
use NinjaEMP\Tenancy\TenantResolver;
use NinjaEMP\Tests\Support\TestController;
use NinjaEMP\Tests\TestHarness;

require_once __DIR__ . '/Support/TestController.php';

return static function (TestHarness $t): void {
    $t->suite('Http');

    // ---- PSR-7 messages ---------------------------------------------------
    $stream = Stream::fromString('hello world');
    $t->assertSame('hello world', (string) $stream, 'stream round-trips a string');
    $t->assertSame(11, $stream->getSize(), 'stream size');
    $t->assertTrue($stream->isReadable(), 'temp stream is readable');
    $stream->rewind();
    $t->assertSame('hello', $stream->read(5), 'stream read honours length');

    $uri = new Uri('https://acme.ninjaemp.app:8443/pos?x=1#frag');
    $t->assertSame('https', $uri->getScheme(), 'uri scheme');
    $t->assertSame('acme.ninjaemp.app', $uri->getHost(), 'uri host');
    $t->assertSame(8443, $uri->getPort(), 'uri non-default port');
    $t->assertSame('/pos', $uri->getPath(), 'uri path');
    $t->assertSame('x=1', $uri->getQuery(), 'uri query');
    $t->assertSame('frag', $uri->getFragment(), 'uri fragment');
    $t->assertSame(null, (new Uri('https://a.b/c'))->getPort(), 'default port hidden');

    $response = new Response(201, 'created', ['Content-Type' => 'text/plain']);
    $t->assertSame(201, $response->getStatusCode(), 'response status');
    $t->assertSame('Created', $response->getReasonPhrase(), 'response reason');
    $t->assertSame('text/plain', $response->getHeaderLine('content-type'), 'header case-insensitive');
    $t->assertTrue($response->hasHeader('CONTENT-TYPE'), 'hasHeader case-insensitive');
    $t->assertSame(404, $response->withStatus(404)->getStatusCode(), 'withStatus immutable');
    $t->assertSame(201, $response->getStatusCode(), 'original response unchanged');

    $req = new ServerRequest('POST', new Uri('http://localhost/things'), [], 'a=1');
    $t->assertSame('POST', $req->getMethod(), 'request method');
    $t->assertSame('/things', $req->getUri()->getPath(), 'request path');
    $t->assertSame('a=1', (string) $req->getBody(), 'request body');
    $t->assertSame('fallback', $req->getAttribute('missing', 'fallback'), 'attribute default');
    $t->assertSame('v', $req->withAttribute('k', 'v')->getAttribute('k'), 'attribute set');

    // ---- Attribute routing ------------------------------------------------
    $collection = new RouteCollection();
    $collection->addController(TestController::class);
    $t->assertSame(6, $collection->count(), 'six routes discovered from attributes');

    $router = new Router($collection);
    $match = $router->match('GET', '/');
    $t->assertSame(TestController::class, $match?->controller, 'home route controller');
    $t->assertSame('home', $match?->action, 'home route action');
    $t->assertTrue($match?->public ?? false, 'home route is public');

    $match = $router->match('GET', '/vendors/42');
    $t->assertSame('42', $match?->params['id'] ?? null, 'path param captured');
    $t->assertSame('vendors.manage', $match?->permission, 'route permission captured');

    $t->assertSame(null, $router->match('GET', '/nope'), 'unknown path does not match');
    $t->assertSame(null, $router->match('DELETE', '/'), 'wrong method does not match');
    $t->assertSame('things.write', $router->match('PUT', '/things')?->name, 'multi-method route matches PUT');
    $t->assertSame('things.write', $router->match('POST', '/things')?->name, 'multi-method route matches POST');

    // ---- Kernel: happy path ----------------------------------------------
    $kernel = new HttpKernel($router, new ControllerResolver());
    $res = $kernel->handle(new ServerRequest('GET', new Uri('http://localhost/')));
    $t->assertSame(200, $res->getStatusCode(), 'kernel dispatches public route');
    $t->assertSame('home', (string) $res->getBody(), 'kernel returns controller body');

    $res = $kernel->handle(new ServerRequest('GET', new Uri('http://localhost/vendors/7')));
    $t->assertSame(200, $res->getStatusCode(), 'kernel dispatches param route');
    $t->assertTrue(str_contains((string) $res->getBody(), '"id": "7"') || str_contains((string) $res->getBody(), '"id":"7"'), 'json body carries param');

    // ---- Kernel: 404 ------------------------------------------------------
    $t->assertThrows(
        NotFoundException::class,
        fn () => $kernel->handle(new ServerRequest('GET', new Uri('http://localhost/missing'))),
        'unmatched route throws NotFound'
    );

    // ---- RBAC -------------------------------------------------------------
    $_SESSION = [];
    $auth = new SessionAuth();
    $rbacKernel = new HttpKernel($router, new ControllerResolver());
    $rbacKernel->pipe(new AuthMiddleware($auth));
    $rbacKernel->pipeAfterRouting(new RbacMiddleware());

    $t->assertThrows(
        UnauthorizedException::class,
        fn () => $rbacKernel->handle(new ServerRequest('GET', new Uri('http://localhost/secure'))),
        'anonymous request to protected route is 401'
    );

    $auth->login(new User('u-1', 'Dana', Role::of(Role::CASHIER), 't-1'));
    $t->assertThrows(
        AccessDeniedException::class,
        fn () => $rbacKernel->handle(new ServerRequest('GET', new Uri('http://localhost/secure'))),
        'cashier denied settings.manage'
    );

    $res = $rbacKernel->handle(new ServerRequest('GET', new Uri('http://localhost/pos')));
    $t->assertSame(200, $res->getStatusCode(), 'cashier allowed pos.use');

    $auth->login(new User('u-2', 'Owen', Role::of(Role::OWNER), 't-1'));
    $res = $rbacKernel->handle(new ServerRequest('GET', new Uri('http://localhost/secure')));
    $t->assertSame(200, $res->getStatusCode(), 'owner allowed settings.manage');

    // ---- Tenant middleware ------------------------------------------------
    $registry = new InMemoryTenantRegistry();
    $registry->add(new TenantRecord('t-1', 'acme', 'tenant_acme', 'Acme Mall'), 'acme.ninjaemp.app');
    $resolver = new TenantResolver($registry);

    $tenantKernel = new HttpKernel($router, new ControllerResolver());
    $tenantKernel->pipe(new TenantMiddleware($resolver));

    $res = $tenantKernel->handle(new ServerRequest('GET', new Uri('http://acme.ninjaemp.app/echo-tenant')));
    $t->assertSame(200, $res->getStatusCode(), 'tenant resolved by host');
    $t->assertTrue(str_contains((string) $res->getBody(), 'tenant_acme'), 'tenant schema attached to request');

    $t->assertThrows(
        TenantNotResolvedException::class,
        fn () => $tenantKernel->handle(new ServerRequest('GET', new Uri('http://unknown.example/echo-tenant'))),
        'unknown host cannot resolve a tenant'
    );

    // ---- CSRF -------------------------------------------------------------
    $_SESSION = [];
    $csrf = new Csrf();
    $token = $csrf->token();
    $csrfKernel = new HttpKernel($router, new ControllerResolver());
    $csrfKernel->pipeAfterRouting(new CsrfMiddleware($csrf));

    $res = $csrfKernel->handle(new ServerRequest('GET', new Uri('http://localhost/')));
    $t->assertSame(200, $res->getStatusCode(), 'safe method bypasses CSRF');

    $t->assertThrows(
        \NinjaEMP\Http\Exception\HttpException::class,
        fn () => $csrfKernel->handle(new ServerRequest('POST', new Uri('http://localhost/things'))),
        'POST without token is rejected'
    );

    $post = new ServerRequest('POST', new Uri('http://localhost/things'), [], null, ['X-CSRF-Token' => $token]);
    $res = $csrfKernel->handle($post);
    $t->assertSame(201, $res->getStatusCode(), 'POST with valid header token passes');

    $postBody = new ServerRequest('POST', new Uri('http://localhost/things'));
    $postBody = $postBody->withParsedBody(['_csrf' => $token]);
    $res = $csrfKernel->handle($postBody);
    $t->assertSame(201, $res->getStatusCode(), 'POST with valid body token passes');

    // ---- Error handler ----------------------------------------------------
    $errorKernel = new HttpKernel($router, new ControllerResolver());
    $errorKernel->pipe(new ErrorHandlerMiddleware(new ErrorRenderer(false)));

    $res = $errorKernel->handle(new ServerRequest('GET', new Uri('http://localhost/missing')));
    $t->assertSame(404, $res->getStatusCode(), 'error handler renders 404');
    $t->assertTrue(str_contains($res->getHeaderLine('Content-Type'), 'text/html'), 'browser gets HTML error');

    $apiReq = new ServerRequest('GET', new Uri('http://localhost/api/missing'), [], null, ['Accept' => 'application/json']);
    $res = $errorKernel->handle($apiReq);
    $t->assertSame(404, $res->getStatusCode(), 'api 404 status');
    $t->assertTrue(str_contains($res->getHeaderLine('Content-Type'), 'application/json'), 'api gets JSON error');
    $t->assertTrue(str_contains((string) $res->getBody(), '"status": 404') || str_contains((string) $res->getBody(), '"status":404'), 'json error envelope');

    // ---- Pipeline ordering ------------------------------------------------
    $order = [];
    $mk = static function (string $tag) use (&$order): \Psr\Http\Server\MiddlewareInterface {
        return new class ($tag, $order) implements \Psr\Http\Server\MiddlewareInterface {
            /** @param array<int,string> $order */
            public function __construct(private string $tag, private array &$order)
            {
            }

            public function process(\Psr\Http\Message\ServerRequestInterface $request, \Psr\Http\Server\RequestHandlerInterface $handler): \Psr\Http\Message\ResponseInterface
            {
                $this->order[] = $this->tag . ':in';
                $response = $handler->handle($request);
                $this->order[] = $this->tag . ':out';

                return $response;
            }
        };
    };

    $pipeKernel = new HttpKernel($router, new ControllerResolver());
    $pipeKernel->pipe($mk('a'));
    $pipeKernel->pipe($mk('b'));
    $pipeKernel->handle(new ServerRequest('GET', new Uri('http://localhost/')));
    $t->assertSame(['a:in', 'b:in', 'b:out', 'a:out'], $order, 'middleware nest in order (onion)');
};
