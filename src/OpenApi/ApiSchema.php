<?php

declare(strict_types=1);

namespace NinjaEMP\OpenApi;

use Attribute;

/**
 * Declares the request/response schema for an attribute-routed controller
 * method, so the OpenAPI document can be generated from the code itself.
 *
 * Usage:
 *   #[ApiSchema(
 *       summary: 'List vendors',
 *       response: 'VendorList',
 *       tags: ['Vendors'],
 *   )]
 */
#[Attribute(Attribute::TARGET_METHOD | Attribute::IS_REPEATABLE)]
final class ApiSchema
{
    /**
     * @param list<string> $tags
     * @param array<int, string> $errors
     */
    public function __construct(
        public readonly string $summary = '',
        public readonly string $description = '',
        public readonly ?string $request = null,
        public readonly ?string $response = null,
        public readonly array $tags = [],
        public readonly array $errors = [],
        public readonly bool $deprecated = false,
    ) {
    }
}
