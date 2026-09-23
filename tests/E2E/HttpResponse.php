<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\E2E;

use JsonException;
use RuntimeException;

/**
 * A captured HTTP response from an end-to-end request.
 *
 * Deliberately tiny: status, raw body, and the raw header lines. Helpers decode
 * JSON and assert on content so the E2E tests read like the journeys they prove.
 */
final class HttpResponse
{
    /**
     * @param list<string> $headers
     */
    public function __construct(
        public readonly int $status,
        public readonly string $body,
        public readonly array $headers = [],
    ) {
    }

    /**
     * Decode the body as a JSON object.
     *
     * @return array<string,mixed>
     */
    public function json(): array
    {
        try {
            /** @var mixed $decoded */
            $decoded = json_decode($this->body, true, 512, JSON_THROW_ON_ERROR);
        } catch (JsonException $e) {
            throw new RuntimeException('Response body is not valid JSON: ' . $e->getMessage(), 0, $e);
        }

        if (!\is_array($decoded)) {
            throw new RuntimeException('Response JSON is not an object/array.');
        }

        /** @var array<string,mixed> $decoded */
        return $decoded;
    }

    public function contains(string $needle): bool
    {
        return str_contains($this->body, $needle);
    }

    public function header(string $name): ?string
    {
        $needle = strtolower($name) . ':';

        foreach ($this->headers as $header) {
            if (str_starts_with(strtolower($header), $needle)) {
                return trim(substr($header, \strlen($needle)));
            }
        }

        return null;
    }
}
