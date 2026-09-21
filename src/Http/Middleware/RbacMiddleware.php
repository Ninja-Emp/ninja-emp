<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Middleware;

use NinjaEMP\Auth\User;
use NinjaEMP\Http\Exception\AccessDeniedException;
use NinjaEMP\Http\Exception\UnauthorizedException;
use NinjaEMP\Http\Routing\RouteMatch;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * Enforces the route's declared permission (server-side authority).
 *
 * Public routes pass through. Otherwise the request must carry an authenticated
 * principal (401) that holds the route's permission (403). The route match is
 * attached by the kernel as a request attribute before this runs.
 */
final class RbacMiddleware implements MiddlewareInterface
{
    public const ATTRIBUTE = 'route';

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $match = $request->getAttribute(self::ATTRIBUTE);

        if (!$match instanceof RouteMatch || $match->public || $match->permission === null) {
            return $handler->handle($request);
        }

        $user = $request->getAttribute(AuthMiddleware::ATTRIBUTE);

        if (!$user instanceof User) {
            throw new UnauthorizedException();
        }

        if (!$user->can($match->permission)) {
            throw new AccessDeniedException($match->permission);
        }

        return $handler->handle($request);
    }
}
