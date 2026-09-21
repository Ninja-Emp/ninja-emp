<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use NinjaEMP\Repository\Repository;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Vendor (party) read surface. Demonstrates a container-injected dependency
 * (the repository) and RBAC on a resource route.
 */
final class VendorController
{
    public function __construct(private readonly Repository $repository)
    {
    }

    #[Route('GET', '/api/vendors', name: 'vendors.index', permission: 'vendors.manage')]
    #[ApiSchema(
        summary: 'List vendors',
        description: 'Returns every vendor (party with a vendor role) for the tenant.',
        response: 'VendorList',
        tags: ['Vendors'],
        errors: [401, 403],
    )]
    public function index(ServerRequestInterface $request, array $params): ResponseInterface
    {
        return JsonResponse::of(['data' => $this->repository->vendors()]);
    }

    #[Route('GET', '/api/vendors/{id}', name: 'vendors.show', permission: 'vendors.manage')]
    #[ApiSchema(
        summary: 'Get a vendor',
        description: 'Returns a single vendor by id.',
        response: 'VendorEnvelope',
        tags: ['Vendors'],
        errors: [401, 403, 404],
    )]
    public function show(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $vendor = $this->repository->vendor((string) ($params['id'] ?? ''));

        if ($vendor === null) {
            return JsonResponse::error('Vendor not found.', 404);
        }

        return JsonResponse::of(['data' => $vendor]);
    }
}
