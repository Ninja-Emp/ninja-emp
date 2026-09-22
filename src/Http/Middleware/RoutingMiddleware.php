<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Middleware;

use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Http\Routing\Router;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * Matches the request against the route table and attaches the RouteMatch as a
 * request attribute. Runs inside the pipeline (after the error handler) so a
 * 404 is rendered cleanly, and before RBAC so the declared permission is known.
 */
final class RoutingMiddleware implements MiddlewareInterface
{
    public const ATTRIBUTE = 'route';

    public function __construct(private readonly Router $router)
    {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $match = $this->router->match(
            $request->getMethod(),
            $request->getUri()->getPath(),
        );

        if ($match === null) {
            throw new NotFoundException(\sprintf(
                'No route matches %s %s.',
                $request->getMethod(),
                $request->getUri()->getPath(),
            ));
        }

        return $handler->handle($request->withAttribute(self::ATTRIBUTE, $match));
    }
}
