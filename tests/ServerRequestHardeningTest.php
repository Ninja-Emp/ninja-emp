<?php

declare(strict_types=1);

/**
 * ServerRequest immutability hardening.
 *
 * The surviving mutants were the `clone $this` statements in the with* methods:
 * a removed clone would mutate the original in place. These tests assert that
 * every with* method returns a new instance and leaves the receiver untouched.
 */

use NinjaEMP\Http\Message\ServerRequest;
use NinjaEMP\Http\Message\Uri;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('ServerRequest (hardening)');

    $base = new ServerRequest('GET', new Uri('http://host.test/path?q=1'), ['k' => 'v'], 'raw', ['X-A' => '1', 'Host' => 'host.test']);

    // ---- withRequestTarget -------------------------------------------------
    $mutated = $base->withRequestTarget('/other');
    $t->assertSame('/other', $mutated->getRequestTarget(), 'withRequestTarget sets the target');
    $t->assertSame('/path?q=1', $base->getRequestTarget(), 'withRequestTarget leaves the original untouched');
    $t->assertTrue($mutated !== $base, 'withRequestTarget returns a new instance');

    // ---- withMethod --------------------------------------------------------
    $mutated = $base->withMethod('post');
    $t->assertSame('POST', $mutated->getMethod(), 'withMethod upper-cases');
    $t->assertSame('GET', $base->getMethod(), 'withMethod leaves the original untouched');

    // ---- withUri -----------------------------------------------------------
    $mutated = $base->withUri(new Uri('http://other.test/x'));
    $t->assertSame('other.test', $mutated->getUri()->getHost(), 'withUri sets the uri');
    $t->assertSame('host.test', $base->getUri()->getHost(), 'withUri leaves the original untouched');

    // preserveHost keeps the original Host header.
    $preserved = $base->withUri(new Uri('http://other.test/x'), true);
    $t->assertSame('host.test', $preserved->getHeaderLine('Host'), 'preserveHost keeps the original host header');

    // ---- withCookieParams --------------------------------------------------
    $mutated = $base->withCookieParams(['sid' => 42]);
    $t->assertSame(['sid' => '42'], $mutated->getCookieParams(), 'withCookieParams stringifies values');
    $t->assertSame([], $base->getCookieParams(), 'withCookieParams leaves the original untouched');

    // ---- withQueryParams ---------------------------------------------------
    $mutated = $base->withQueryParams(['page' => 2]);
    $t->assertSame(['page' => 2], $mutated->getQueryParams(), 'withQueryParams sets the query');
    $t->assertSame([], $base->getQueryParams(), 'withQueryParams leaves the original untouched');

    // ---- withUploadedFiles -------------------------------------------------
    $mutated = $base->withUploadedFiles(['f' => 'x']);
    $t->assertSame(['f' => 'x'], $mutated->getUploadedFiles(), 'withUploadedFiles sets the files');
    $t->assertSame([], $base->getUploadedFiles(), 'withUploadedFiles leaves the original untouched');

    // ---- withParsedBody ----------------------------------------------------
    $mutated = $base->withParsedBody(['p' => 1]);
    $t->assertSame(['p' => 1], $mutated->getParsedBody(), 'withParsedBody sets an array body');
    $t->assertSame(null, $base->getParsedBody(), 'withParsedBody leaves the original untouched');

    $obj = new stdClass();
    $t->assertSame($obj, $base->withParsedBody($obj)->getParsedBody(), 'withParsedBody keeps an object body');
    $t->assertSame(null, $base->withParsedBody('scalar')->getParsedBody(), 'withParsedBody nulls a scalar body');

    // ---- withAttribute / withoutAttribute ----------------------------------
    $mutated = $base->withAttribute('a', 'v');
    $t->assertSame('v', $mutated->getAttribute('a'), 'withAttribute sets the attribute');
    $t->assertSame([], $base->getAttributes(), 'withAttribute leaves the original untouched');

    $withTwo = $base->withAttribute('a', 'v')->withAttribute('b', 'w');
    $t->assertSame(['a' => 'v', 'b' => 'w'], $withTwo->getAttributes(), 'attributes accumulate on the clone');
    $t->assertSame(['b' => 'w'], $withTwo->withoutAttribute('a')->getAttributes(), 'withoutAttribute removes one');
    $t->assertSame(['a' => 'v', 'b' => 'w'], $withTwo->getAttributes(), 'withoutAttribute leaves the original untouched');

    // getAttribute returns the default for a missing name.
    $t->assertSame('fallback', $base->getAttribute('missing', 'fallback'), 'getAttribute returns the default');

    // ---- header-name normalisation from server vars -----------------------
    $req = ServerRequest::fromGlobals([
        'REQUEST_METHOD' => 'GET',
        'HTTP_HOST' => 'h.test',
        'HTTP_X_CUSTOM_HEADER' => 'yes',
        'CONTENT_TYPE' => 'application/json',
        'CONTENT_LENGTH' => '12',
    ]);
    $t->assertSame('yes', $req->getHeaderLine('X-Custom-Header'), 'HTTP_ header name is normalised');
    $t->assertSame('application/json', $req->getHeaderLine('Content-Type'), 'CONTENT_TYPE becomes a header');
    $t->assertSame('12', $req->getHeaderLine('Content-Length'), 'CONTENT_LENGTH becomes a header');

    // HTTPS=on selects the https scheme.
    $secure = ServerRequest::fromGlobals(['HTTPS' => 'on', 'HTTP_HOST' => 's.test']);
    $t->assertSame('https', $secure->getUri()->getScheme(), 'HTTPS=on selects https');

    // A missing REQUEST_URI defaults to '/'.
    $root = ServerRequest::fromGlobals(['HTTP_HOST' => 'r.test']);
    $t->assertSame('/', $root->getUri()->getPath(), 'missing REQUEST_URI defaults to /');
};
