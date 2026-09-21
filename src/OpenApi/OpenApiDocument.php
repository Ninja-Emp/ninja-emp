<?php

declare(strict_types=1);

namespace NinjaEMP\OpenApi;

use NinjaEMP\Http\Routing\Route;
use NinjaEMP\Http\Routing\RouteCollection;
use ReflectionClass;
use ReflectionMethod;

/**
 * Builds an OpenAPI 3.1 document from attribute-routed controllers.
 *
 * The document is generated from the same #[Route] attributes the kernel uses,
 * so the contract can never drift from the implementation. Response/request
 * schemas are declared with #[ApiSchema] and referenced by name from the
 * components section.
 */
final class OpenApiDocument
{
    /** @var array<string, array<string, mixed>> */
    private array $schemas = [];

    /** @var array<string, array<string, mixed>> */
    private array $paths = [];

    /** @var list<array{name:string,description?:string}> */
    private array $tags = [];

    /** @var list<array{url:string,description?:string}> */
    private array $servers = [];

    public function __construct(
        private readonly string $title,
        private readonly string $version,
        private readonly string $description = '',
    ) {
    }

    public function server(string $url, string $description = ''): self
    {
        $server = ['url' => $url];
        if ($description !== '') {
            $server['description'] = $description;
        }
        $this->servers[] = $server;

        return $this;
    }

    public function tag(string $name, string $description = ''): self
    {
        $tag = ['name' => $name];
        if ($description !== '') {
            $tag['description'] = $description;
        }
        $this->tags[] = $tag;

        return $this;
    }

    /**
     * Register a named component schema.
     *
     * @param Schema|array<string, mixed> $schema
     */
    public function schema(string $name, Schema|array $schema): self
    {
        $this->schemas[$name] = $schema instanceof Schema ? $schema->toArray() : $schema;

        return $this;
    }

    /**
     * Reflect a controller class and add its #[Route] methods as operations.
     *
     * @param class-string $controller
     */
    public function addController(string $controller): self
    {
        $reflection = new ReflectionClass($controller);

        foreach ($reflection->getMethods(ReflectionMethod::IS_PUBLIC) as $method) {
            if ($method->isStatic() || $method->isConstructor()) {
                continue;
            }

            $routeAttributes = $method->getAttributes(Route::class);
            if ($routeAttributes === []) {
                continue;
            }

            $apiAttributes = $method->getAttributes(ApiSchema::class);
            /** @var ApiSchema|null $api */
            $api = $apiAttributes !== [] ? $apiAttributes[0]->newInstance() : null;

            foreach ($routeAttributes as $routeAttribute) {
                /** @var Route $route */
                $route = $routeAttribute->newInstance();
                $this->addOperation($route, $api);
            }
        }

        return $this;
    }

    private function addOperation(Route $route, ?ApiSchema $api): void
    {
        $path = $this->toOpenApiPath($route->path);
        $this->paths[$path] ??= [];

        foreach ($route->methodList() as $method) {
            $operation = [
                'operationId' => $route->name ?? $this->deriveOperationId($method, $route->path),
                'responses' => $this->responses($api),
            ];

            if ($api !== null) {
                if ($api->summary !== '') {
                    $operation['summary'] = $api->summary;
                }
                if ($api->description !== '') {
                    $operation['description'] = $api->description;
                }
                if ($api->tags !== []) {
                    $operation['tags'] = $api->tags;
                }
                if ($api->deprecated) {
                    $operation['deprecated'] = true;
                }
                if ($api->request !== null) {
                    $operation['requestBody'] = [
                        'required' => true,
                        'content' => [
                            'application/json' => [
                                'schema' => ['$ref' => '#/components/schemas/' . $api->request],
                            ],
                        ],
                    ];
                }
            }

            $parameters = $this->pathParameters($route->path);
            if ($parameters !== []) {
                $operation['parameters'] = $parameters;
            }

            if (!$route->public) {
                $operation['security'] = [['sessionAuth' => []]];
            }

            $this->paths[$path][strtolower($method)] = $operation;
        }
    }

    /**
     * @return array<string, mixed>
     */
    private function responses(?ApiSchema $api): array
    {
        $success = [
            'description' => 'Successful response',
        ];

        if ($api !== null && $api->response !== null) {
            $success['content'] = [
                'application/json' => [
                    'schema' => ['$ref' => '#/components/schemas/' . $api->response],
                ],
            ];
        }

        $responses = ['200' => $success];

        if ($api !== null) {
            foreach ($api->errors as $code) {
                $responses[(string) $code] = [
                    'description' => $this->errorDescription((int) $code),
                    'content' => [
                        'application/json' => [
                            'schema' => ['$ref' => '#/components/schemas/Error'],
                        ],
                    ],
                ];
            }
        }

        return $responses;
    }

    /**
     * @return list<array<string, mixed>>
     */
    private function pathParameters(string $path): array
    {
        if (preg_match_all('#\{([a-zA-Z_][a-zA-Z0-9_]*)\}#', $path, $matches) === 0) {
            return [];
        }

        $parameters = [];
        foreach ($matches[1] as $name) {
            $parameters[] = [
                'name' => $name,
                'in' => 'path',
                'required' => true,
                'schema' => ['type' => 'string'],
            ];
        }

        return $parameters;
    }

    private function toOpenApiPath(string $path): string
    {
        return '/' . trim($path, '/');
    }

    private function deriveOperationId(string $method, string $path): string
    {
        $slug = trim(preg_replace('#[^a-zA-Z0-9]+#', '_', $path) ?? '', '_');

        return strtolower($method) . '_' . ($slug === '' ? 'root' : $slug);
    }

    private function errorDescription(int $code): string
    {
        return match ($code) {
            400 => 'Bad request',
            401 => 'Authentication required',
            403 => 'Access denied',
            404 => 'Not found',
            409 => 'Conflict',
            422 => 'Validation failed',
            default => 'Error',
        };
    }

    /**
     * @return array<string, mixed>
     */
    public function toArray(): array
    {
        $document = [
            'openapi' => '3.1.0',
            'info' => array_filter([
                'title' => $this->title,
                'version' => $this->version,
                'description' => $this->description !== '' ? $this->description : null,
            ], static fn ($v): bool => $v !== null),
        ];

        if ($this->servers !== []) {
            $document['servers'] = $this->servers;
        }
        if ($this->tags !== []) {
            $document['tags'] = $this->tags;
        }

        $document['paths'] = $this->paths === [] ? new \stdClass() : $this->paths;

        $document['components'] = [
            'schemas' => $this->schemas,
            'securitySchemes' => [
                'sessionAuth' => [
                    'type' => 'apiKey',
                    'in' => 'cookie',
                    'name' => 'PHPSESSID',
                    'description' => 'Session cookie established by the login endpoint.',
                ],
            ],
        ];

        return $document;
    }

    public function toJson(): string
    {
        $json = json_encode(
            $this->toArray(),
            JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE
        );

        return $json === false ? '{}' : $json;
    }
}
