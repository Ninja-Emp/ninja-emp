<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Middleware;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * A PSR-15 middleware pipeline.
 *
 * Middleware are executed in the order given (first = outermost). Each receives
 * the request and a handler that invokes the next middleware; the terminal
 * handler is the kernel's route dispatcher.
 */
final class Pipeline implements RequestHandlerInterface
{
    /** @var list<MiddlewareInterface> */
    private array $middleware = [];

    public function __construct(private readonly RequestHandlerInterface $terminal)
    {
    }

    public function pipe(MiddlewareInterface $middleware): self
    {
        $this->middleware[] = $middleware;

        return $this;
    }

    public function handle(ServerRequestInterface $request): ResponseInterface
    {
        $handler = $this->terminal;

        // Wrap from the inside out so the first-piped middleware is outermost.
        foreach (array_reverse($this->middleware) as $middleware) {
            $next = $handler;
            $handler = new class ($middleware, $next) implements RequestHandlerInterface {
                public function __construct(
                    private readonly MiddlewareInterface $middleware,
                    private readonly RequestHandlerInterface $next,
                ) {
                }

                public function handle(ServerRequestInterface $request): ResponseInterface
                {
                    return $this->middleware->process($request, $this->next);
                }
            };
        }

        return $handler->handle($request);
    }
}
