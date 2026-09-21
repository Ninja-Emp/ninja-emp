<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Middleware;

use NinjaEMP\Http\ErrorRenderer;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;
use NinjaEMP\Support\Log\NullLogger;
use Psr\Log\LoggerInterface;
use Throwable;

/**
 * Catches any throwable from the inner stack and renders a clean response.
 * Outermost middleware, so nothing escapes to the SAPI as a stack trace.
 */
final class ErrorHandlerMiddleware implements MiddlewareInterface
{
    public function __construct(
        private readonly ErrorRenderer $renderer,
        private readonly LoggerInterface $logger = new NullLogger(),
    ) {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        try {
            return $handler->handle($request);
        } catch (Throwable $error) {
            $this->logger->error('Unhandled request error: {message}', [
                'message' => $error->getMessage(),
                'exception' => $error,
                'path' => $request->getUri()->getPath(),
            ]);

            return $this->renderer->render($request, $error);
        }
    }
}
