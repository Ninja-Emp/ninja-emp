<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Routing;

use Attribute;

/**
 * Marks a controller method as an HTTP route (attribute-based routing).
 *
 * Usage:
 *   #[Route('GET', '/vendors/{id}', name: 'vendors.show', permission: 'vendors.manage')]
 *   public function show(array $params): ResponseInterface { ... }
 */
#[Attribute(Attribute::TARGET_METHOD | Attribute::IS_REPEATABLE)]
final class Route
{
    /**
     * @param list<string> $methods
     */
    public function __construct(
        public readonly array|string $methods,
        public readonly string $path,
        public readonly ?string $name = null,
        public readonly ?string $permission = null,
        public readonly bool $public = false,
    ) {
    }

    /** @return list<string> */
    public function methodList(): array
    {
        $methods = \is_array($this->methods) ? $this->methods : [$this->methods];

        return array_values(array_map(static fn (string $m): string => strtoupper($m), $methods));
    }
}
