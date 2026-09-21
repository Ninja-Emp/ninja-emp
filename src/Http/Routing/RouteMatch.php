<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Routing;

/**
 * The result of matching a request against the route table.
 */
final class RouteMatch
{
    /**
     * @param array<string, string> $params
     */
    public function __construct(
        public readonly string $controller,
        public readonly string $action,
        public readonly array $params,
        public readonly ?string $name,
        public readonly ?string $permission,
        public readonly bool $public,
    ) {
    }
}
