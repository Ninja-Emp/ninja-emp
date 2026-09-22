<?php

declare(strict_types=1);

namespace NinjaEMP\OpenApi;

/**
 * A small builder for JSON Schema 2020-12 fragments (the dialect OpenAPI 3.1
 * uses). Immutable-ish: each `with*` returns a clone so schemas can be shared.
 */
final class Schema
{
    /** @var array<string, mixed> */
    private array $schema;

    /**
     * @param array<string, mixed> $schema
     */
    private function __construct(array $schema)
    {
        $this->schema = $schema;
    }

    public static function string(?string $format = null, ?string $description = null): self
    {
        $schema = ['type' => 'string'];

        if ($format !== null) {
            $schema['format'] = $format;
        }

        if ($description !== null) {
            $schema['description'] = $description;
        }

        return new self($schema);
    }

    public static function integer(?string $description = null): self
    {
        return new self(array_filter([
            'type' => 'integer',
            'description' => $description,
        ], static fn ($v): bool => $v !== null));
    }

    public static function number(?string $description = null): self
    {
        return new self(array_filter([
            'type' => 'number',
            'description' => $description,
        ], static fn ($v): bool => $v !== null));
    }

    public static function boolean(?string $description = null): self
    {
        return new self(array_filter([
            'type' => 'boolean',
            'description' => $description,
        ], static fn ($v): bool => $v !== null));
    }

    /**
     * A money value: a decimal string with 4 dp (ADR-0002 — never a float).
     */
    public static function money(string $currency = 'USD'): self
    {
        return new self([
            'type' => 'string',
            'pattern' => '^-?\\d+\\.\\d{4}$',
            'description' => \sprintf('Monetary amount in %s, 4 decimal places (string, never a float).', $currency),
            'examples' => ['0.0000', '19.9900'],
        ]);
    }

    public static function ref(string $name): self
    {
        return new self(['$ref' => '#/components/schemas/' . $name]);
    }

    /**
     * @param Schema|array<string, mixed> $items
     */
    public static function array(self|array $items, ?string $description = null): self
    {
        $schema = [
            'type' => 'array',
            'items' => $items instanceof self ? $items->toArray() : $items,
        ];

        if ($description !== null) {
            $schema['description'] = $description;
        }

        return new self($schema);
    }

    /**
     * @param array<string, Schema|array<string, mixed>> $properties
     * @param list<string> $required
     */
    public static function object(array $properties, array $required = [], ?string $description = null): self
    {
        $props = [];

        foreach ($properties as $name => $property) {
            $props[$name] = $property instanceof self ? $property->toArray() : $property;
        }

        $schema = ['type' => 'object', 'properties' => $props];

        if ($required !== []) {
            $schema['required'] = $required;
        }

        if ($description !== null) {
            $schema['description'] = $description;
        }

        return new self($schema);
    }

    /**
     * @param list<string> $values
     */
    public static function enum(array $values, ?string $description = null): self
    {
        $schema = ['type' => 'string', 'enum' => $values];

        if ($description !== null) {
            $schema['description'] = $description;
        }

        return new self($schema);
    }

    public function withDescription(string $description): self
    {
        $clone = clone $this;
        $clone->schema['description'] = $description;

        return $clone;
    }

    public function nullable(): self
    {
        $clone = clone $this;
        $clone->schema['type'] = [$clone->schema['type'] ?? 'string', 'null'];

        return $clone;
    }

    public function withExample(mixed $example): self
    {
        $clone = clone $this;
        $clone->schema['examples'] = [$example];

        return $clone;
    }

    /** @return array<string, mixed> */
    public function toArray(): array
    {
        return $this->schema;
    }
}
