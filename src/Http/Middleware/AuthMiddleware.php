<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Middleware;

use NinjaEMP\Auth\SessionAuth;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * Rehydrates the authenticated principal from the session and attaches it to the
 * request. Never rejects on its own — RBAC is enforced by RbacMiddleware against
 * the route's declared permission, so public routes still work.
 */
final class AuthMiddleware implements MiddlewareInterface
{
    public const ATTRIBUTE = 'user';

    public function __construct(private readonly SessionAuth $auth)
    {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $user = $this->auth->user();

        if ($user !== null) {
            $request = $request->withAttribute(self::ATTRIBUTE, $user);
        }

        return $handler->handle($request);
    }
}
