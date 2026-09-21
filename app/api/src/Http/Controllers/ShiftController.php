<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use InvalidArgumentException;
use NinjaEMP\Domain\Pos\ShiftService;
use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Register and shift (cash-drawer session) surface.
 *
 * Opening a shift and closing it (with over/short posting) are the two
 * state-changing operations; the rest are reads.
 */
final class ShiftController
{
    public function __construct(private readonly ShiftService $shifts)
    {
    }

    #[Route('POST', '/api/registers', name: 'registers.store', permission: 'registers.manage')]
    #[ApiSchema(
        summary: 'Create a register',
        description: 'Creates a checkout station.',
        tags: ['Registers'],
        errors: [401, 403, 422],
    )]
    public function storeRegister(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $body = $this->body($request);

        try {
            $id = $this->shifts->createRegister(
                (string) ($body['code'] ?? ''),
                (string) ($body['name'] ?? ''),
                isset($body['location_id']) ? (string) $body['location_id'] : null,
            );
        } catch (InvalidArgumentException $e) {
            return JsonResponse::error($e->getMessage(), 422);
        }

        return JsonResponse::of(['data' => ['id' => $id]], 201);
    }

    #[Route('POST', '/api/registers/{id}/shifts', name: 'shifts.open', permission: 'pos.use')]
    #[ApiSchema(
        summary: 'Open a shift',
        description: 'Opens a cash-drawer session on a register with an opening float.',
        tags: ['Registers'],
        errors: [401, 403, 422],
    )]
    public function open(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $body = $this->body($request);

        try {
            $id = $this->shifts->openShift(
                (string) ($params['id'] ?? ''),
                (string) ($body['opening_float'] ?? '0'),
                isset($body['opened_by_party_id']) ? (string) $body['opened_by_party_id'] : null,
                (string) ($body['currency'] ?? 'USD'),
            );
        } catch (InvalidArgumentException $e) {
            return JsonResponse::error($e->getMessage(), 422);
        }

        return JsonResponse::of(['data' => ['id' => $id]], 201);
    }

    #[Route('GET', '/api/registers/{id}/shift', name: 'shifts.current', permission: 'pos.use')]
    #[ApiSchema(
        summary: 'Current shift',
        description: 'The currently open shift on a register, if any.',
        tags: ['Registers'],
        errors: [401, 403],
    )]
    public function current(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $shift = $this->shifts->openShiftFor((string) ($params['id'] ?? ''));

        return JsonResponse::of(['data' => $shift]);
    }

    #[Route('POST', '/api/shifts/{id}/close', name: 'shifts.close', permission: 'pos.use')]
    #[ApiSchema(
        summary: 'Close a shift',
        description: 'Records counted cash, computes over/short and posts it (ADR-0029).',
        tags: ['Registers'],
        errors: [401, 403, 422],
    )]
    public function close(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $body = $this->body($request);
        $counted = (string) ($body['counted_cash'] ?? '');

        if ($counted === '') {
            return JsonResponse::error('counted_cash is required.', 422);
        }

        $entry = $this->shifts->closeShift(
            (string) ($params['id'] ?? ''),
            $counted,
            isset($body['entry_date']) ? (string) $body['entry_date'] : null,
            isset($body['idempotency_key']) ? (string) $body['idempotency_key'] : null,
        );

        return JsonResponse::of([
            'data' => [
                'journal_entry_id' => $entry,
                'balanced' => $entry === null,
            ],
        ]);
    }

    #[Route('GET', '/api/shifts/{id}/preview', name: 'shifts.preview', permission: 'pos.use')]
    #[ApiSchema(
        summary: 'Preview shift close',
        description: 'Computes expected cash and over/short without posting.',
        tags: ['Registers'],
        errors: [401, 403],
    )]
    public function preview(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $counted = $this->query($request, 'counted_cash') ?? '0';

        return JsonResponse::of(['data' => $this->shifts->previewClose((string) ($params['id'] ?? ''), $counted)]);
    }

    /**
     * @return array<string, mixed>
     */
    private function body(ServerRequestInterface $request): array
    {
        $body = $request->getParsedBody();

        return is_array($body) ? $body : [];
    }

    private function query(ServerRequestInterface $request, string $key): ?string
    {
        $params = $request->getQueryParams();
        $value = $params[$key] ?? null;

        return is_string($value) && $value !== '' ? $value : null;
    }
}
