<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Middleware;

use NinjaEMP\Http\Exception\TenantNotResolvedException;
use NinjaEMP\Tenancy\TenantResolver;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Server\MiddlewareInterface;
use Psr\Http\Server\RequestHandlerInterface;

/**
 * Resolves the request to a tenant (schema-per-tenant, ADR-0008) and attaches
 * the TenantContext as a request attribute. Downstream code (the DBAL, the
 * repository) reads it to set `search_path` inside every transaction.
 *
 * Resolution order: an explicit `X-Tenant` header / `tenant` query param, then
 * the request host (subdomain routing).
 */
final class TenantMiddleware implements MiddlewareInterface
{
    public const ATTRIBUTE = 'tenant';

    public function __construct(
        private readonly TenantResolver $resolver,
        private readonly bool $required = true,
    ) {
    }

    public function process(ServerRequestInterface $request, RequestHandlerInterface $handler): ResponseInterface
    {
        $slug = $this->slug($request);
        $host = $request->getUri()->getHost();

        $tenant = $this->resolver->resolve($slug, $host);

        if ($tenant === null) {
            if ($this->required) {
                throw new TenantNotResolvedException();
            }

            return $handler->handle($request);
        }

        return $handler->handle($request->withAttribute(self::ATTRIBUTE, $tenant));
    }

    private function slug(ServerRequestInterface $request): ?string
    {
        $header = $request->getHeaderLine('X-Tenant');

        if ($header !== '') {
            return $header;
        }

        $query = $request->getQueryParams();
        $value = $query['tenant'] ?? null;

        return \is_string($value) && $value !== '' ? $value : null;
    }
}
