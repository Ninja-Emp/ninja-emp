<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use NinjaEMP\Auth\User;
use NinjaEMP\Db\TenantContext;
use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * The current principal + resolved tenant. Requires authentication.
 */
final class MeController
{
    /**
     * @param array<string,mixed> $params
     */
    #[Route('GET', '/api/me', name: 'me', permission: 'dashboard.view')]
    #[ApiSchema(
        summary: 'Current principal',
        description: 'Returns the authenticated user and the resolved tenant.',
        response: 'Me',
        tags: ['System'],
        errors: [401, 403],
    )]
    public function me(ServerRequestInterface $request, array $params): ResponseInterface
    {
        /** @var User|null $user */
        $user = $request->getAttribute('user');
        /** @var TenantContext|null $tenant */
        $tenant = $request->getAttribute('tenant');

        return JsonResponse::of([
            'user' => [
                'id' => $user?->id,
                'name' => $user?->name,
                'role' => $user?->role->code(),
                'initials' => $user?->initials(),
            ],
            'tenant' => [
                'id' => $tenant?->tenantId(),
                'schema' => $tenant?->schema(),
            ],
        ]);
    }
}
