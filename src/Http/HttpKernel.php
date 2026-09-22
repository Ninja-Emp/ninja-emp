<?php

declare(strict_types=1);

namespace NinjaEMP\Http;

use NinjaEMP\Http\Exception\NotFoundException;
use NinjaEMP\Http\Middleware\Pipeline;
use NinjaEMP\Http\Middleware\RoutingMiddleware;
use NinjaEMP\Http\Routing\Router;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;
use ReflectionMethod;
use RuntimeException;

/**
 * The HTTP kernel.
 *
 * Assembles a PSR-15 pipeline in a fixed, predictable order:
 *
 *   [ pre-routing middleware ]  ← error handler, tenant, auth
 *   RoutingMiddleware           ← matches the route, attaches the RouteMatch
 *   [ post-routing middleware ] ← RBAC, CSRF
 *   Dispatch                    ← instantiates the controller, calls the action
 *
 * Routing sits between the two phases so RBAC can read the route's declared
 * permission, while the error handler stays outermost and can render a clean
 * 404/500. The kernel is transport-agnostic (takes and returns PSR-7 messages)
 * so it can be exercised in tests without a web server.
 */
final class HttpKernel
{
    /** @var list<MiddlewareInterface> */
    private array $preRouting = [];

    /** @var list<MiddlewareInterface> */
    private array $postRouting = [];

    public function __construct(
        private readonly Router $router,
        private readonly ControllerResolver $resolver,
    ) {
    }

    /** Pipe middleware that runs before route matching (error, tenant, auth). */
    public function pipe(MiddlewareInterface $middleware): self
    {
        $this->preRouting[] = $middleware;

        return $this;
    }

    /** Pipe middleware that runs after route matching (rbac, csrf). */
    public function pipeAfterRouting(MiddlewareInterface $middleware): self
    {
        $this->postRouting[] = $middleware;

        return $this;
    }

    public function handle(ServerRequestInterface $request): ResponseInterface
    {
        $pipeline = new Pipeline($this->terminal());

        foreach ($this->preRouting as $middleware) {
            $pipeline->pipe($middleware);
        }

        $pipeline->pipe(new RoutingMiddleware($this->router));

        foreach ($this->postRouting as $middleware) {
            $pipeline->pipe($middleware);
        }

        return $pipeline->handle($request);
    }

    private function terminal(): RequestHandlerInterface
    {
        return new class ($this->resolver) implements RequestHandlerInterface {
            private ControllerResolver $resolver;

            public function __construct(ControllerResolver $resolver)
            {
                $this->resolver = $resolver;
            }

            public function handle(ServerRequestInterface $request): ResponseInterface
            {
                $match = $request->getAttribute(RoutingMiddleware::ATTRIBUTE);

                if (!$match instanceof Routing\RouteMatch) {
                    throw new NotFoundException('No route matched the request.');
                }

                $controllerClass = $match->controller;

                if (!class_exists($controllerClass)) {
                    throw new NotFoundException(\sprintf('Controller "%s" not found.', $controllerClass));
                }

                $controller = $this->resolver->resolve($controllerClass);
                $action = $match->action;

                if (!method_exists($controller, $action)) {
                    throw new NotFoundException(\sprintf(
                        'Action "%s::%s" not found.',
                        $match->controller,
                        $action,
                    ));
                }

                $response = (new ReflectionMethod($controller, $action))->invoke($controller, $request, $match->params);

                if (!$response instanceof ResponseInterface) {
                    throw new RuntimeException(\sprintf(
                        'Controller %s::%s must return a PSR-7 ResponseInterface.',
                        $match->controller,
                        $action,
                    ));
                }

                return $response;
            }
        };
    }
}
