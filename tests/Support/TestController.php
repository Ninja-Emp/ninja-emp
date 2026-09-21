<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\Support;

use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Routing\Route;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * A controller fixture exercising attribute routing, RBAC and params.
 */
final class TestController
{
    #[Route('GET', '/', name: 'home', public: true)]
    public function home(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, 'home');
    }

    #[Route('GET', '/secure', name: 'secure', permission: 'settings.manage')]
    public function secure(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, 'secure');
    }

    #[Route('GET', '/pos', name: 'pos', permission: 'pos.use')]
    public function pos(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(200, 'pos');
    }

    #[Route('GET', '/vendors/{id}', name: 'vendors.show', permission: 'vendors.manage')]
    public function showVendor(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return JsonResponse::of(['id' => $params['id'] ?? null]);
    }

    #[Route(['POST', 'PUT'], '/things', name: 'things.write', permission: 'inventory.manage')]
    public function writeThing(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return new Response(201, 'created');
    }

    #[Route('GET', '/echo-tenant', name: 'echo.tenant', public: true)]
    public function echoTenant(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $tenant = $request->getAttribute('tenant');

        return JsonResponse::of(['schema' => $tenant?->schema()]);
    }
}
