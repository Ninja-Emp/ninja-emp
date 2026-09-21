<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use NinjaEMP\Auth\User;
use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * The current principal + resolved tenant. Requires authentication.
 */
final class MeController
{
    #[Route('GET', '/api/me', name: 'me', permission: 'dashboard.view')]
    public function me(ServerRequestInterface $request, array $params): ResponseInterface
    {
        /** @var User|null $user */
        $user = $request->getAttribute('user');
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
