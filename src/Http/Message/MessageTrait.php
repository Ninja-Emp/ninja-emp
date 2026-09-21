<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use InvalidArgumentException;
use Psr\Http\Message\StreamInterface;

/**
 * Shared header + protocol handling for PSR-7 messages.
 */
trait MessageTrait
{
    private string $protocolVersion = '1.1';

    /** @var array<string, list<string>> lower-cased name => values */
    private array $headers = [];

    /** @var array<string, string> lower-cased name => original name */
    private array $headerNames = [];

    private ?StreamInterface $body = null;

    public function getProtocolVersion(): string
    {
        return $this->protocolVersion;
    }

    public function withProtocolVersion(string $version): static
    {
        $clone = clone $this;
        $clone->protocolVersion = $version;

        return $clone;
    }

    /** @return array<string, list<string>> */
    public function getHeaders(): array
    {
        return $this->headers;
    }

    public function hasHeader(string $name): bool
    {
        return isset($this->headers[strtolower($name)]);
    }

    /** @return list<string> */
    public function getHeader(string $name): array
    {
        return $this->headers[strtolower($name)] ?? [];
    }

    public function getHeaderLine(string $name): string
    {
        return implode(', ', $this->getHeader($name));
    }

    public function withHeader(string $name, $value): static
    {
        $this->assertHeaderName($name);
        $clone = clone $this;
        $normalized = strtolower($name);
        $clone->headerNames[$normalized] = $name;
        $clone->headers[$normalized] = $this->normalizeValue($value);

        return $clone;
    }

    public function withAddedHeader(string $name, $value): static
    {
        $this->assertHeaderName($name);
        $clone = clone $this;
        $normalized = strtolower($name);
        $clone->headerNames[$normalized] = $name;
        $clone->headers[$normalized] = array_merge(
            $clone->headers[$normalized] ?? [],
            $this->normalizeValue($value)
        );

        return $clone;
    }

    public function withoutHeader(string $name): static
    {
        $normalized = strtolower($name);
        if (!isset($this->headers[$normalized])) {
            return $this;
        }
        $clone = clone $this;
        unset($clone->headers[$normalized], $clone->headerNames[$normalized]);

        return $clone;
    }

    public function getBody(): StreamInterface
    {
        if ($this->body === null) {
            $this->body = Stream::fromString();
        }

        return $this->body;
    }

    public function withBody(StreamInterface $body): static
    {
        $clone = clone $this;
        $clone->body = $body;

        return $clone;
    }

    /**
     * @param string|list<string> $value
     *
     * @return list<string>
     */
    private function normalizeValue($value): array
    {
        if (is_string($value)) {
            return [$value];
        }
        if (is_array($value)) {
            return array_values(array_map(static fn ($v): string => (string) $v, $value));
        }

        return [(string) $value];
    }

    private function assertHeaderName(string $name): void
    {
        if ($name === '' || preg_match('/^[!#$%&\'*+.^_`|~0-9A-Za-z-]+$/', $name) !== 1) {
            throw new InvalidArgumentException(sprintf('Invalid header name: "%s".', $name));
        }
    }
}
