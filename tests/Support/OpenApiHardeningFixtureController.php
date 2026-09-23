<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\Support;

use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Fixture controller for OpenApiHardeningTest. Exercises the branches the
 * document builder takes that the primary fixture does not: a constructor and
 * a static method (both skipped), a route with no name (operationId derived
 * from the path), a root path, a deprecated operation, an operation with no
 * ApiSchema at all, and every declared error code.
 */
final class OpenApiHardeningFixtureController
{
    public function __construct()
    {
    }

    #[Route('GET', '/api/ignored-static', name: 'ignored.static')]
    public static function ignoredStatic(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    /** A public method with no #[Route] attribute is skipped entirely. */
    public function notARoute(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    /** A route with no name forces operationId derivation from the path. */
    #[Route('GET', '/api/derived/thing')]
    public function derived(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    /** A root path derives the "root" slug. */
    #[Route('GET', '/')]
    public function root(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    /** No ApiSchema: operation carries only operationId + responses. */
    #[Route('GET', '/api/bare', name: 'bare')]
    public function bare(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    /** Deprecated + description + every declared error code. */
    #[Route('DELETE', '/api/legacy/{id}', name: 'legacy.destroy')]
    #[ApiSchema(
        summary: 'Destroy legacy',
        description: 'Deprecated endpoint.',
        deprecated: true,
        errors: [400, 401, 403, 404, 409, 422, 500],
    )]
    public function legacy(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    /** Multiple HTTP verbs on one path. */
    #[Route(['GET', 'POST'], '/api/multi', name: 'multi')]
    public function multi(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }
}
