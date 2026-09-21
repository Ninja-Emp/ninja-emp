<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\Support;

use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Fixture controller for OpenApiTest. Exercises every attribute feature the
 * document builder reflects: public vs protected routes, path parameters,
 * request bodies, declared errors, and response schema refs.
 */
final class OpenApiFixtureController
{
    #[Route('GET', '/api/ping', name: 'ping', public: true)]
    #[ApiSchema(summary: 'Ping', tags: ['System'])]
    public function ping(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    #[Route('GET', '/api/things', name: 'things.index', permission: 'things.view')]
    #[ApiSchema(summary: 'List things', tags: ['Things'], response: 'ThingList')]
    public function index(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '[]', ['Content-Type' => 'application/json']);
    }

    #[Route('GET', '/api/things/{id}', name: 'things.show', permission: 'things.view')]
    #[ApiSchema(summary: 'Show a thing', tags: ['Things'], response: 'Thing', errors: [404])]
    public function show(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, '{}', ['Content-Type' => 'application/json']);
    }

    #[Route('POST', '/api/things', name: 'things.store', permission: 'things.manage')]
    #[ApiSchema(summary: 'Create a thing', tags: ['Things'], request: 'Thing', response: 'Thing', errors: [422])]
    public function store(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(201, '{}', ['Content-Type' => 'application/json']);
    }
}
