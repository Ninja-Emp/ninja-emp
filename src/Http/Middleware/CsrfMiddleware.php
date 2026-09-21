<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Middleware;

use NinjaEMP\Auth\Csrf;
use NinjaEMP\Http\Exception\HttpException;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * Validates the CSRF token on state-changing requests (POST/PUT/PATCH/DELETE).
 *
 * The token is read from the parsed body (`_csrf`) or the `X-CSRF-Token` header.
 * JSON API clients may present the header; browser forms use the hidden field.
 */
final class CsrfMiddleware implements MiddlewareInterface
{
    private const SAFE_METHODS = ['GET', 'HEAD', 'OPTIONS'];

    public function __construct(private readonly Csrf $csrf)
    {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        if (in_array($request->getMethod(), self::SAFE_METHODS, true)) {
            return $handler->handle($request);
        }

        $token = $this->token($request);

        if (!$this->csrf->validate($token)) {
            throw new HttpException(419, 'Your session expired. Please refresh and try again.');
        }

        return $handler->handle($request);
    }

    private function token(ServerRequestInterface $request): ?string
    {
        $header = $request->getHeaderLine('X-CSRF-Token');
        if ($header !== '') {
            return $header;
        }

        $body = $request->getParsedBody();
        if (is_array($body) && isset($body[Csrf::FIELD]) && is_string($body[Csrf::FIELD])) {
            return $body[Csrf::FIELD];
        }

        return null;
    }
}
