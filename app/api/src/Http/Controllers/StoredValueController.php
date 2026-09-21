<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use InvalidArgumentException;
use NinjaEMP\Domain\StoredValue\StoredValueService;
use NinjaEMP\Http\Message\JsonResponse;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;

/**
 * Stored value surface: gift certificates and store credit (ADR-0032).
 *
 * Issuing creates a liability; redemption draws it down. Breakage is opt-in.
 */
final class StoredValueController
{
    public function __construct(private readonly StoredValueService $storedValue)
    {
    }

    #[Route('POST', '/api/stored-value', name: 'stored_value.issue', permission: 'stored_value.manage')]
    #[ApiSchema(
        summary: 'Issue stored value',
        description: 'Issues a gift certificate or store credit as a liability.',
        tags: ['Stored value'],
        errors: [401, 403, 422],
    )]
    public function issue(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $body = $this->body($request);

        try {
            $id = $this->storedValue->issue(
                (string) ($body['instrument_kind'] ?? ''),
                (string) ($body['code'] ?? ''),
                (string) ($body['amount'] ?? ''),
                isset($body['party_id']) ? (string) $body['party_id'] : null,
                isset($body['entry_date']) ? (string) $body['entry_date'] : null,
                (bool) ($body['paid_with_cash'] ?? true),
                isset($body['expires_date']) ? (string) $body['expires_date'] : null,
                isset($body['idempotency_key']) ? (string) $body['idempotency_key'] : null,
            );
        } catch (InvalidArgumentException $e) {
            return JsonResponse::error($e->getMessage(), 422);
        }

        return JsonResponse::of(['data' => ['id' => $id]], 201);
    }

    #[Route('GET', '/api/stored-value/{code}', name: 'stored_value.show', permission: 'stored_value.manage')]
    #[ApiSchema(
        summary: 'Get stored value',
        description: 'Looks up an instrument by code.',
        tags: ['Stored value'],
        errors: [401, 403, 404],
    )]
    public function show(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $instrument = $this->storedValue->find((string) ($params['code'] ?? ''));

        if ($instrument === null) {
            return JsonResponse::error('Stored value not found.', 404);
        }

        return JsonResponse::of(['data' => $instrument]);
    }

    #[Route('POST', '/api/stored-value/{code}/redeem', name: 'stored_value.redeem', permission: 'stored_value.manage')]
    #[ApiSchema(
        summary: 'Redeem stored value',
        description: 'Draws down an instrument; requires a sale or journal entry for GL linkage.',
        tags: ['Stored value'],
        errors: [401, 403, 422],
    )]
    public function redeem(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $body = $this->body($request);

        try {
            $entry = $this->storedValue->redeem(
                (string) ($params['code'] ?? ''),
                (string) ($body['amount'] ?? ''),
                isset($body['entry_date']) ? (string) $body['entry_date'] : null,
                isset($body['sale_id']) ? (string) $body['sale_id'] : null,
                isset($body['entry_id']) ? (string) $body['entry_id'] : null,
            );
        } catch (InvalidArgumentException $e) {
            return JsonResponse::error($e->getMessage(), 422);
        }

        return JsonResponse::of(['data' => ['journal_entry_id' => $entry]]);
    }

    #[Route('GET', '/api/stored-value/outstanding/{kind}', name: 'stored_value.outstanding', permission: 'stored_value.manage')]
    #[ApiSchema(
        summary: 'Outstanding stored value',
        description: 'The outstanding liability for an instrument kind.',
        tags: ['Stored value'],
        errors: [401, 403],
    )]
    public function outstanding(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $kind = (string) ($params['kind'] ?? '');

        return JsonResponse::of([
            'data' => [
                'instrument_kind' => $kind,
                'outstanding' => $this->storedValue->outstanding($kind),
            ],
        ]);
    }

    /**
     * @return array<string, mixed>
     */
    private function body(ServerRequestInterface $request): array
    {
        $body = $request->getParsedBody();

        return is_array($body) ? $body : [];
    }
}
