<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Liveness/readiness probe. Public — no auth, no tenant required.
 */
final class HealthController
{
    #[Route('GET', '/api/health', name: 'health', public: true)]
    public function health(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return JsonResponse::of([
            'status' => 'ok',
            'service' => 'ninja-emp-api',
            'time' => (new \DateTimeImmutable())->format(\DateTimeInterface::ATOM),
        ]);
    }
}
