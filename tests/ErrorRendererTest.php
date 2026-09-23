<?php

declare(strict_types=1);

/**
 * ErrorRenderer hardening.
 *
 * The renderer content-negotiates between a JSON envelope and an HTML page and
 * gates stack traces behind the debug flag. These tests pin the status mapping,
 * the negotiation rules, the JSON payload shape, the debug trace, and the full
 * status-title table.
 */

use NinjaEMP\Http\ErrorRenderer;
use NinjaEMP\Http\Exception\AccessDeniedException;
use NinjaEMP\Http\Exception\HttpException;
use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Http\Exception\UnauthorizedException;
use NinjaEMP\Http\Message\ServerRequest;
use NinjaEMP\Http\Message\Uri;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('ErrorRenderer');

    $renderer = new ErrorRenderer(false);

    // ---- status mapping ---------------------------------------------------
    $req = new ServerRequest('GET', new Uri('http://h.test/page'));

    $res = $renderer->render($req, new NotFoundException());
    $t->assertSame(404, $res->getStatusCode(), 'HttpException status is used');

    $res = $renderer->render($req, new AccessDeniedException());
    $t->assertSame(403, $res->getStatusCode(), 'AccessDenied maps to 403');

    $res = $renderer->render($req, new UnauthorizedException());
    $t->assertSame(401, $res->getStatusCode(), 'Unauthorized maps to 401');

    $res = $renderer->render($req, new RuntimeException('boom'));
    $t->assertSame(500, $res->getStatusCode(), 'a generic throwable maps to 500');

    // ---- content negotiation ----------------------------------------------
    $htmlReq = new ServerRequest('GET', new Uri('http://h.test/page'));
    $res = $renderer->render($htmlReq, new NotFoundException());
    $t->assertTrue(str_contains($res->getHeaderLine('Content-Type'), 'text/html'), 'a browser request gets HTML');

    $acceptJson = new ServerRequest('GET', new Uri('http://h.test/page'), [], null, ['Accept' => 'application/json']);
    $res = $renderer->render($acceptJson, new NotFoundException());
    $t->assertTrue(str_contains($res->getHeaderLine('Content-Type'), 'application/json'), 'Accept: application/json gets JSON');

    $apiPath = new ServerRequest('GET', new Uri('http://h.test/api/things'));
    $res = $renderer->render($apiPath, new NotFoundException());
    $t->assertTrue(str_contains($res->getHeaderLine('Content-Type'), 'application/json'), '/api/ path gets JSON');

    // A non-API path with no Accept header stays HTML.
    $plain = new ServerRequest('GET', new Uri('http://h.test/things'), [], null, ['Accept' => 'text/html']);
    $res = $renderer->render($plain, new NotFoundException());
    $t->assertTrue(str_contains($res->getHeaderLine('Content-Type'), 'text/html'), 'text/html Accept stays HTML');

    // ---- JSON payload -----------------------------------------------------
    $res = $renderer->render($acceptJson, new NotFoundException('No such thing.'));
    $payload = json_decode((string) $res->getBody(), true);
    $t->assertSame(404, $payload['error']['status'], 'JSON envelope carries the status');
    $t->assertSame('No such thing.', $payload['error']['message'], 'JSON envelope carries the message');
    $t->assertFalse(isset($payload['error']['type']), 'non-debug JSON omits the exception type');
    $t->assertFalse(isset($payload['error']['trace']), 'non-debug JSON omits the trace');

    // ---- debug mode adds type + trace for non-HTTP errors -----------------
    $debug = new ErrorRenderer(true);
    $res = $debug->render($acceptJson, new RuntimeException('kaboom'));
    $payload = json_decode((string) $res->getBody(), true);
    $t->assertSame(RuntimeException::class, $payload['error']['type'], 'debug JSON includes the exception type');
    $t->assertTrue(is_array($payload['error']['trace']), 'debug JSON includes the trace as an array');

    // Debug mode does NOT leak a trace for an HttpException.
    $res = $debug->render($acceptJson, new NotFoundException());
    $payload = json_decode((string) $res->getBody(), true);
    $t->assertFalse(isset($payload['error']['type']), 'debug JSON hides the type for HttpException');
    $t->assertFalse(isset($payload['error']['trace']), 'debug JSON hides the trace for HttpException');

    // ---- HTML title table -------------------------------------------------
    $titles = [
        400 => 'Bad request',
        401 => 'Authentication required',
        403 => 'Access denied',
        404 => 'Not found',
        405 => 'Method not allowed',
        409 => 'Conflict',
        422 => 'Unprocessable entity',
        429 => 'Too many requests',
        500 => 'Something went wrong',
    ];
    foreach ($titles as $status => $title) {
        $res = $renderer->render($htmlReq, new HttpException($status));
        $body = (string) $res->getBody();
        $t->assertSame($status, $res->getStatusCode(), "status {$status} rendered");
        $t->assertTrue(str_contains($body, $title), "title for {$status} is \"{$title}\"");
    }

    // ---- HTML escaping ----------------------------------------------------
    $res = $renderer->render($htmlReq, new NotFoundException('<script>alert(1)</script>'));
    $body = (string) $res->getBody();
    $t->assertFalse(str_contains($body, '<script>alert(1)</script>'), 'HTML message is escaped');
    $t->assertTrue(str_contains($body, '&lt;script&gt;'), 'HTML message is entity-encoded');

    // Debug HTML includes a trace block for non-HTTP errors.
    $res = $debug->render($htmlReq, new RuntimeException('kaboom'));
    $t->assertTrue(str_contains((string) $res->getBody(), 'class="trace"'), 'debug HTML includes a trace block');

    // Non-debug HTML omits the trace block.
    $res = $renderer->render($htmlReq, new RuntimeException('kaboom'));
    $t->assertFalse(str_contains((string) $res->getBody(), 'class="trace"'), 'non-debug HTML omits the trace block');
};
