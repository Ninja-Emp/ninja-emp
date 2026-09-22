<?php

declare(strict_types=1);

use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Message\Request;
use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Message\ServerRequest;
use NinjaEMP\Http\Message\Stream;
use NinjaEMP\Http\Message\Uri;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('HttpMessage');

    // ---- Uri --------------------------------------------------------------

    $empty = new Uri();
    $t->assertSame('', $empty->getScheme(), 'empty uri has no scheme');
    $t->assertSame('', $empty->getAuthority(), 'empty uri has no authority');
    $t->assertSame('', (string) $empty, 'empty uri stringifies to empty');

    $uri = new Uri('https://user:secret@example.com:8443/a/b?x=1&y=2#frag');
    $t->assertSame('https', $uri->getScheme(), 'scheme lower-cased');
    $t->assertSame('user:secret@example.com:8443', $uri->getAuthority(), 'authority includes userinfo + port');
    $t->assertSame('user:secret', $uri->getUserInfo(), 'userinfo');
    $t->assertSame('example.com', $uri->getHost(), 'host lower-cased');
    $t->assertSame(8443, $uri->getPort(), 'explicit port');
    $t->assertSame('/a/b', $uri->getPath(), 'path');
    $t->assertSame('x=1&y=2', $uri->getQuery(), 'query');
    $t->assertSame('frag', $uri->getFragment(), 'fragment');
    $t->assertSame('https://user:secret@example.com:8443/a/b?x=1&y=2#frag', (string) $uri, 'round-trips');

    // Default ports collapse to null.
    $t->assertSame(null, (new Uri('http://example.com:80/'))->getPort(), 'http:80 collapses');
    $t->assertSame(null, (new Uri('https://example.com:443/'))->getPort(), 'https:443 collapses');
    $t->assertSame(8080, (new Uri('http://example.com:8080/'))->getPort(), 'non-default port kept');

    // Immutable withers.
    $t->assertSame('ftp', $uri->withScheme('FTP')->getScheme(), 'withScheme lower-cases');
    $t->assertSame('bob', $uri->withUserInfo('bob')->getUserInfo(), 'withUserInfo without password');
    $t->assertSame('bob:pw', $uri->withUserInfo('bob', 'pw')->getUserInfo(), 'withUserInfo with password');
    $t->assertSame('other.test', $uri->withHost('Other.Test')->getHost(), 'withHost lower-cases');
    $t->assertSame(1234, $uri->withPort(1234)->getPort(), 'withPort sets');
    $t->assertSame(null, $uri->withPort(null)->getPort(), 'withPort null clears');
    $t->assertSame('/new', $uri->withPath('/new')->getPath(), 'withPath');
    $t->assertSame('a=1', $uri->withQuery('?a=1')->getQuery(), 'withQuery strips leading ?');
    $t->assertSame('top', $uri->withFragment('#top')->getFragment(), 'withFragment strips leading #');

    // Authority without host is empty even with a scheme.
    $t->assertSame('', (new Uri('mailto:foo@bar'))->getAuthority(), 'no host -> no authority');

    // Validation.
    $t->assertThrows(InvalidArgumentException::class, fn () => $uri->withPort(70000), 'port too high rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $uri->withPort(-1), 'negative port rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => new Uri('http://'), 'unparseable uri rejected');

    // ---- Stream -----------------------------------------------------------

    $stream = Stream::fromString('hello world');
    $t->assertSame(11, $stream->getSize(), 'size of string stream');
    $t->assertTrue($stream->isSeekable(), 'temp stream is seekable');
    $t->assertTrue($stream->isReadable(), 'temp stream is readable');
    $t->assertTrue($stream->isWritable(), 'temp stream is writable');
    $t->assertSame('hello world', $stream->getContents(), 'getContents');
    $t->assertSame(11, $stream->tell(), 'tell at end');
    $t->assertTrue($stream->eof(), 'eof after full read');
    $stream->rewind();
    $t->assertSame(0, $stream->tell(), 'tell after rewind');
    $t->assertSame('hello world', (string) $stream, 'string cast rewinds and reads');

    $stream->rewind();
    $t->assertSame('hello', $stream->read(5), 'read n bytes');
    $t->assertSame(5, $stream->tell(), 'tell advances');
    $t->assertSame('', $stream->read(0), 'read zero returns empty');
    $t->assertThrows(RuntimeException::class, fn () => $stream->read(-1), 'negative read rejected');

    $stream->rewind();
    $t->assertSame(3, $stream->write('XYZ'), 'write returns byte count');

    $stream->seek(0);
    $t->assertSame('XYZlo world', $stream->getContents(), 'overwrite from start');

    $meta = $stream->getMetadata();
    $t->assertTrue(is_array($meta), 'getMetadata returns array');
    $t->assertSame(true, $stream->getMetadata('seekable'), 'getMetadata by key');
    $t->assertSame(null, $stream->getMetadata('nope'), 'unknown metadata key is null');

    $detached = Stream::fromString('abc');
    $resource = $detached->detach();
    $t->assertTrue(is_resource($resource), 'detach returns the resource');
    $t->assertSame(null, $detached->getSize(), 'detached stream has no size');
    $t->assertSame('', (string) $detached, 'detached stream stringifies empty');
    $t->assertTrue($detached->eof(), 'detached stream is eof');
    $t->assertSame([], $detached->getMetadata(), 'detached metadata is empty array');
    $t->assertSame(null, $detached->getMetadata('seekable'), 'detached metadata key is null');
    $t->assertThrows(RuntimeException::class, fn () => $detached->tell(), 'tell on detached throws');
    $t->assertThrows(RuntimeException::class, fn () => $detached->read(1), 'read on detached throws');
    $t->assertThrows(RuntimeException::class, fn () => $detached->write('x'), 'write on detached throws');
    $t->assertThrows(RuntimeException::class, fn () => $detached->getContents(), 'getContents on detached throws');

    $closable = Stream::fromString('bye');
    $closable->close();
    $t->assertSame(null, $closable->getSize(), 'closed stream has no size');

    // A socket pair is not seekable: exercise the guard.
    $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);

    if ($pair !== false) {
        $socketStream = Stream::fromResource($pair[0]);
        $t->assertFalse($socketStream->isSeekable(), 'socket stream is not seekable');
        $t->assertThrows(RuntimeException::class, fn () => $socketStream->seek(0), 'seek on non-seekable throws');
        $socketStream->close();
        fclose($pair[1]);
    }

    // ---- Request ----------------------------------------------------------

    $request = new Request('get', new Uri('http://example.com/path?x=1'), 'body', ['X-Test' => 'v']);
    $t->assertSame('GET', $request->getMethod(), 'method upper-cased');
    $t->assertSame('/path?x=1', $request->getRequestTarget(), 'request target from uri');
    $t->assertSame('v', $request->getHeaderLine('x-test'), 'header case-insensitive');
    $t->assertSame('body', (string) $request->getBody(), 'body stream');

    $t->assertSame('/custom', $request->withRequestTarget('/custom')->getRequestTarget(), 'withRequestTarget');
    $t->assertSame('POST', $request->withMethod('post')->getMethod(), 'withMethod upper-cases');
    $t->assertSame('example.com', $request->getUri()->getHost(), 'getUri');

    $withUri = $request->withUri(new Uri('http://other.test/'));
    $t->assertSame('other.test', $withUri->getHeaderLine('Host'), 'withUri sets Host header');
    $preserved = $request->withUri(new Uri('http://other.test/'), true);
    $t->assertSame('', $preserved->getHeaderLine('Host'), 'preserveHost keeps existing Host');

    $noPath = new Request('GET', new Uri('http://example.com'));
    $t->assertSame('/', $noPath->getRequestTarget(), 'empty path becomes /');

    // ---- ServerRequest ----------------------------------------------------

    $server = new ServerRequest('post', new Uri('http://h/p'), ['k' => 'v'], 'raw', ['Content-Type' => 'text/plain']);
    $t->assertSame('POST', $server->getMethod(), 'server method upper-cased');
    $t->assertSame(['k' => 'v'], $server->getServerParams(), 'server params');
    $t->assertSame('text/plain', $server->getHeaderLine('content-type'), 'server header');

    $t->assertSame(['a' => 'b'], $server->withCookieParams(['a' => 'b'])->getCookieParams(), 'withCookieParams');
    $t->assertSame(['q' => '1'], $server->withQueryParams(['q' => '1'])->getQueryParams(), 'withQueryParams');
    $t->assertSame(['f' => 'x'], $server->withUploadedFiles(['f' => 'x'])->getUploadedFiles(), 'withUploadedFiles');
    $t->assertSame([], $server->getUploadedFiles(), 'uploaded files default empty');

    $t->assertSame(['p' => 1], $server->withParsedBody(['p' => 1])->getParsedBody(), 'withParsedBody array');
    $obj = (object) ['p' => 1];
    $t->assertSame($obj, $server->withParsedBody($obj)->getParsedBody(), 'withParsedBody object');
    $t->assertSame(null, $server->withParsedBody('scalar')->getParsedBody(), 'withParsedBody scalar -> null');

    $t->assertSame(null, $server->getAttribute('missing'), 'missing attribute default null');
    $t->assertSame('d', $server->getAttribute('missing', 'd'), 'missing attribute custom default');
    $t->assertSame('v', $server->withAttribute('a', 'v')->getAttribute('a'), 'withAttribute');
    $t->assertSame([], $server->withAttribute('a', 'v')->withoutAttribute('a')->getAttributes(), 'withoutAttribute');
    $t->assertSame([], $server->getAttributes(), 'attributes default empty');

    $t->assertSame('/p', $server->getRequestTarget(), 'server request target');
    $t->assertSame('/z', $server->withRequestTarget('/z')->getRequestTarget(), 'server withRequestTarget');
    $t->assertSame('PUT', $server->withMethod('put')->getMethod(), 'server withMethod');
    $t->assertSame('h', $server->getUri()->getHost(), 'server getUri');
    $t->assertSame('other.test', $server->withUri(new Uri('http://other.test/'))->getHeaderLine('Host'), 'server withUri sets host');

    // fromGlobals: form-encoded path.
    $form = ServerRequest::fromGlobals(
        ['REQUEST_METHOD' => 'POST', 'HTTP_HOST' => 'shop.test', 'REQUEST_URI' => '/cart', 'HTTP_X_CUSTOM' => 'yes', 'CONTENT_TYPE' => 'application/x-www-form-urlencoded', 'CONTENT_LENGTH' => '3'],
        ['page' => '2'],
        ['item' => '5'],
        ['sid' => 'abc'],
    );
    $t->assertSame('POST', $form->getMethod(), 'fromGlobals method');
    $t->assertSame('shop.test', $form->getUri()->getHost(), 'fromGlobals host');
    $t->assertSame('/cart', $form->getUri()->getPath(), 'fromGlobals path');
    $t->assertSame('yes', $form->getHeaderLine('X-Custom'), 'fromGlobals HTTP_ header');
    $t->assertSame('3', $form->getHeaderLine('Content-Length'), 'fromGlobals content length');
    $t->assertSame(['page' => '2'], $form->getQueryParams(), 'fromGlobals query');
    $t->assertSame(['sid' => 'abc'], $form->getCookieParams(), 'fromGlobals cookies');
    $t->assertSame(['item' => '5'], $form->getParsedBody(), 'fromGlobals form body');

    // fromGlobals: JSON content type with an empty CLI body -> null parsed body.
    $json = ServerRequest::fromGlobals(
        ['REQUEST_METHOD' => 'POST', 'HTTPS' => 'on', 'SERVER_NAME' => 'secure.test', 'REQUEST_URI' => '/api', 'CONTENT_TYPE' => 'application/json'],
    );
    $t->assertSame('https', $json->getUri()->getScheme(), 'fromGlobals https detection');
    $t->assertSame('secure.test', $json->getUri()->getHost(), 'fromGlobals SERVER_NAME fallback');
    $t->assertSame(null, $json->getParsedBody(), 'fromGlobals json empty body -> null');

    // HTTPS=off is treated as http.
    $plain = ServerRequest::fromGlobals(['HTTPS' => 'off', 'HTTP_HOST' => 'plain.test']);
    $t->assertSame('http', $plain->getUri()->getScheme(), 'HTTPS=off -> http');

    // ---- Response ---------------------------------------------------------

    $response = new Response(201, 'created', ['X-A' => '1']);
    $t->assertSame(201, $response->getStatusCode(), 'status code');
    $t->assertSame('Created', $response->getReasonPhrase(), 'default reason phrase');
    $t->assertSame('1', $response->getHeaderLine('x-a'), 'response header');
    $t->assertSame('created', (string) $response->getBody(), 'response body');

    $t->assertSame(404, $response->withStatus(404)->getStatusCode(), 'withStatus');
    $t->assertSame('Nope', $response->withStatus(404, 'Nope')->getReasonPhrase(), 'custom reason phrase');
    $t->assertSame('', (new Response(599))->getReasonPhrase(), 'unknown status has empty reason');

    // ---- MessageTrait -----------------------------------------------------

    $t->assertSame('1.1', $response->getProtocolVersion(), 'default protocol version');
    $t->assertSame('2', $response->withProtocolVersion('2')->getProtocolVersion(), 'withProtocolVersion');

    $t->assertTrue($response->hasHeader('X-A'), 'hasHeader true');
    $t->assertFalse($response->hasHeader('X-Missing'), 'hasHeader false');
    $t->assertSame(['1'], $response->getHeader('X-A'), 'getHeader');
    $t->assertSame([], $response->getHeader('X-Missing'), 'getHeader missing empty');

    $multi = $response->withHeader('X-Multi', ['a', 'b']);
    $t->assertSame('a, b', $multi->getHeaderLine('X-Multi'), 'multi-value header line');
    $t->assertSame(['a', 'b'], $multi->getHeader('X-Multi'), 'multi-value header');
    $t->assertSame('a, b, c', $multi->withAddedHeader('X-Multi', 'c')->getHeaderLine('X-Multi'), 'withAddedHeader appends');
    $t->assertSame('', $multi->withoutHeader('X-Multi')->getHeaderLine('X-Multi'), 'withoutHeader removes');
    $t->assertSame($response, $response->withoutHeader('X-Missing'), 'withoutHeader on absent is a no-op');

    // Header values are normalised from scalars.
    $t->assertSame('42', $response->withHeader('X-Num', 42)->getHeaderLine('X-Num'), 'int header normalised');

    // Invalid header names are rejected.
    $t->assertThrows(InvalidArgumentException::class, fn () => $response->withHeader('Bad Header', 'x'), 'invalid header name rejected');
    $t->assertThrows(InvalidArgumentException::class, fn () => $response->withAddedHeader('', 'x'), 'empty header name rejected');

    // Lazy body + withBody.
    $lazy = new Response(200);
    $t->assertSame('', (string) $lazy->getBody(), 'lazy body is empty stream');
    $replacement = Stream::fromString('replaced');
    $t->assertSame('replaced', (string) $lazy->withBody($replacement)->getBody(), 'withBody replaces');

    // ---- JsonResponse -----------------------------------------------------

    $ok = JsonResponse::of(['a' => 1]);
    $t->assertSame(200, $ok->getStatusCode(), 'json ok status');
    $t->assertSame('application/json; charset=utf-8', $ok->getHeaderLine('Content-Type'), 'json content type');
    $t->assertSame('{"a":1}', (string) $ok->getBody(), 'json body');

    $err = JsonResponse::error('boom', 422, ['field' => 'required']);
    $t->assertSame(422, $err->getStatusCode(), 'json error status');
    $decoded = json_decode((string) $err->getBody(), true);
    $t->assertSame('boom', $decoded['error']['message'], 'json error message');
    $t->assertSame(['field' => 'required'], $decoded['error']['details'], 'json error details');

    $plainErr = JsonResponse::error('nope');
    $plainDecoded = json_decode((string) $plainErr->getBody(), true);
    $t->assertFalse(isset($plainDecoded['error']['details']), 'json error without details omits key');
};
