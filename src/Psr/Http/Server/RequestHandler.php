<?php

declare(strict_types=1);

namespace Psr\Http\Server;

use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * A convenience implementation of RequestHandlerInterface that wraps a callable
 * (PSR-15, vendored). Useful as the terminal handler at the end of a pipeline.
 */
final class RequestHandler implements RequestHandlerInterface
{
    /** @var callable(ServerRequestInterface): ResponseInterface */
    private $handler;

    /**
     * @param callable(ServerRequestInterface): ResponseInterface $handler
     */
    public function __construct(callable $handler)
    {
        $this->handler = $handler;
    }

    public function handle(ServerRequestInterface $request): ResponseInterface
    {
        return ($this->handler)($request);
    }
}
