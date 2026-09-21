<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Liveness/readiness probe. Public — no auth, no tenant required.
 */
final class HealthController
{
    #[Route('GET', '/api/health', name: 'health', public: true)]
    #[ApiSchema(
        summary: 'Service health',
        description: 'Liveness probe. Returns 200 when the API process is up.',
        response: 'Health',
        tags: ['System'],
    )]
    public function health(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return JsonResponse::of([
            'status' => 'ok',
            'service' => 'ninja-emp-api',
            'time' => (new \DateTimeImmutable())->format(\DateTimeInterface::ATOM),
        ]);
    }
}
