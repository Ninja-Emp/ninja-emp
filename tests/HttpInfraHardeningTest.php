<?php

declare(strict_types=1);

namespace NinjaEMP\Tests;

use NinjaEMP\Auth\Csrf;
use NinjaEMP\Http\Emitter;
use NinjaEMP\Http\ErrorRenderer;
use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Message\ServerRequest;
use NinjaEMP\Http\Message\Uri;
use NinjaEMP\Http\Middleware\ErrorHandlerMiddleware;
use NinjaEMP\Http\Middleware\Pipeline;
use NinjaEMP\Http\Middleware\RoutingMiddleware;
use NinjaEMP\Http\Routing\RouteCollection;
use NinjaEMP\Http\Routing\Router;
use NinjaEMP\Tests\Support\TestController;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\RequestHandlerInterface;
use Psr\Log\AbstractLogger;
use RuntimeException;

require_once __DIR__ . '/Support/TestController.php';

/** A logger that records every message it receives. */
final class CapturingLogger extends AbstractLogger
{
    /** @var list<array{level:mixed, message:string, context:array<string,mixed>}> */
    public array $records = [];

    /** @param array<string, mixed> $context */
    public function log($level, string|\Stringable $message, array $context = []): void
    {
        $this->records[] = ['level' => $level, 'message' => (string) $message, 'context' => $context];
    }
}

/** A terminal handler that always returns a fixed response. */
final class OkHandler implements RequestHandlerInterface
{
    public function handle(ServerRequestInterface $request): ResponseInterface
    {
        return new Response(200, 'ok');
    }
}

/**
 * Hardening tests for the HTTP infrastructure: the SAPI emitter, the middleware
 * pipeline, routing/error middleware, and CSRF.
 */
return static function (TestHarness $t): void {
    // ---- Emitter ----------------------------------------------------------

    $t->suite('Emitter (hardening)');

    $response = new Response(200, 'hello world', ['X-Test' => 'yes']);
    ob_start();
    (new Emitter())->emit($response);
    $out = ob_get_clean();
    $t->assertSame('hello world', $out, 'emit writes the body');

    // A seekable body is rewound before emitting, so a partially-read body still
    // emits in full.
    $response = new Response(200, 'hello world');
    $response->getBody()->read(6);
    ob_start();
    (new Emitter())->emit($response);
    $out = ob_get_clean();
    $t->assertSame('hello world', $out, 'emit rewinds a seekable body before writing');

    // A response with no reason phrase still emits its body.
    $response = new Response(204, '');
    ob_start();
    (new Emitter())->emit($response);
    $out = ob_get_clean();
    $t->assertSame('', $out, 'emit writes an empty body');

    // ---- Pipeline ---------------------------------------------------------

    $t->suite('Pipeline (hardening)');

    $order = [];
    $mk = static function (string $tag) use (&$order): \Psr\Http\Server\MiddlewareInterface {
        return new class ($tag, $order) implements \Psr\Http\Server\MiddlewareInterface {
            /** @param array<int,string> $order */
            public function __construct(private string $tag, private array &$order)
            {
            }

            public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
            {
                $this->order[] = $this->tag . ':in';
                $response = $handler->handle($request);
                $this->order[] = $this->tag . ':out';

                return $response;
            }
        };
    };

    $pipeline = new Pipeline(new OkHandler());
    $pipeline->pipe($mk('a'))->pipe($mk('b'));
    $res = $pipeline->handle(new ServerRequest('GET', new Uri('http://localhost/')));
    $t->assertSame(200, $res->getStatusCode(), 'the pipeline returns the terminal response');
    $t->assertSame(['a:in', 'b:in', 'b:out', 'a:out'], $order, 'the pipeline nests middleware in order');

    // An empty pipeline just calls the terminal.
    $empty = new Pipeline(new OkHandler());
    $t->assertSame(200, $empty->handle(new ServerRequest('GET', new Uri('http://localhost/')))->getStatusCode(), 'an empty pipeline calls the terminal');

    // ---- RoutingMiddleware ------------------------------------------------

    $t->suite('RoutingMiddleware (hardening)');

    $collection = new RouteCollection();
    $collection->addController(TestController::class);
    $router = new Router($collection);
    $routing = new RoutingMiddleware($router);

    $captured = null;
    $capture = new class ($captured) implements RequestHandlerInterface {
        public function __construct(private mixed &$captured)
        {
        }

        public function handle(ServerRequestInterface $request): ResponseInterface
        {
            $this->captured = $request->getAttribute('route');

            return new Response(200, 'ok');
        }
    };

    $res = $routing->process(new ServerRequest('GET', new Uri('http://localhost/')), $capture);
    $t->assertSame(200, $res->getStatusCode(), 'a matched route passes through');
    $t->assertTrue($captured !== null, 'the route match is attached to the request');

    $t->assertThrows(
        NotFoundException::class,
        static fn () => $routing->process(new ServerRequest('GET', new Uri('http://localhost/nope')), new OkHandler()),
        'an unmatched route is a not-found',
    );

    // ---- ErrorHandlerMiddleware ------------------------------------------

    $t->suite('ErrorHandlerMiddleware (hardening)');

    $logger = new CapturingLogger();
    $mw = new ErrorHandlerMiddleware(new ErrorRenderer(false), $logger);

    $res = $mw->process(new ServerRequest('GET', new Uri('http://localhost/')), new OkHandler());
    $t->assertSame(200, $res->getStatusCode(), 'a clean request passes through');
    $t->assertSame([], $logger->records, 'a clean request logs nothing');

    $boom = new class implements RequestHandlerInterface {
        public function handle(ServerRequestInterface $request): ResponseInterface
        {
            throw new RuntimeException('kaboom');
        }
    };

    $res = $mw->process(new ServerRequest('GET', new Uri('http://localhost/boom')), $boom);
    $t->assertSame(500, $res->getStatusCode(), 'a thrown error renders a 500');
    $t->assertSame(1, \count($logger->records), 'a thrown error is logged once');
    $t->assertSame('error', $logger->records[0]['level'], 'the error is logged at error level');
    $t->assertSame('kaboom', $logger->records[0]['context']['exception']->getMessage(), 'the exception is logged');
    $t->assertSame('/boom', $logger->records[0]['context']['path'], 'the request path is logged');

    // ---- Csrf -------------------------------------------------------------

    $t->suite('Csrf (hardening)');

    $_SESSION = [];
    $csrf = new Csrf();
    $token = $csrf->token();
    $t->assertTrue($token !== '', 'token() generates a token');
    $t->assertSame($token, $csrf->token(), 'token() is stable within a session');
    $t->assertTrue($csrf->validate($token), 'the correct token validates');
    $t->assertFalse($csrf->validate('wrong'), 'a wrong token does not validate');
    $t->assertFalse($csrf->validate(null), 'a null token does not validate');
    $t->assertFalse($csrf->validate(''), 'an empty token does not validate');

    $csrf->rotate();
    $t->assertFalse($csrf->validate($token), 'the old token is invalid after rotation');
    $t->assertTrue($csrf->validate($csrf->token()), 'the rotated token validates');

    // With no token in the session, validation fails.
    $_SESSION = [];
    $t->assertFalse((new Csrf())->validate('anything'), 'validation fails with no session token');

    // A custom session key is honoured.
    $_SESSION = [];
    $custom = new Csrf('custom_csrf');
    $customToken = $custom->token();
    $t->assertTrue(isset($_SESSION['custom_csrf']), 'the custom session key is used');
    $t->assertTrue($custom->validate($customToken), 'the custom-key token validates');
};
