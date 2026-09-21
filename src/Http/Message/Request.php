<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use Psr\Http\Message\RequestInterface;
use Psr\Http\Message\UriInterface;

/**
 * A PSR-7 client-side request.
 */
class Request implements RequestInterface
{
    use MessageTrait;

    private string $method;

    private UriInterface $uri;

    private ?string $requestTarget = null;

    public function __construct(
        string $method = 'GET',
        ?UriInterface $uri = null,
        ?string $body = null,
        array $headers = []
    ) {
        $this->method = strtoupper($method);
        $this->uri = $uri ?? new Uri();
        $this->body = Stream::fromString($body ?? '');

        foreach ($headers as $name => $value) {
            $this->headers[strtolower((string) $name)] = $this->normalizeValue($value);
            $this->headerNames[strtolower((string) $name)] = (string) $name;
        }
    }

    public function getRequestTarget(): string
    {
        if ($this->requestTarget !== null) {
            return $this->requestTarget;
        }

        $target = $this->uri->getPath();
        if ($target === '') {
            $target = '/';
        }
        if ($this->uri->getQuery() !== '') {
            $target .= '?' . $this->uri->getQuery();
        }

        return $target;
    }

    public function withRequestTarget(string $requestTarget): static
    {
        $clone = clone $this;
        $clone->requestTarget = $requestTarget;

        return $clone;
    }

    public function getMethod(): string
    {
        return $this->method;
    }

    public function withMethod(string $method): static
    {
        $clone = clone $this;
        $clone->method = strtoupper($method);

        return $clone;
    }

    public function getUri(): UriInterface
    {
        return $this->uri;
    }

    public function withUri(UriInterface $uri, bool $preserveHost = false): static
    {
        $clone = clone $this;
        $clone->uri = $uri;

        if (!$preserveHost && $uri->getHost() !== '') {
            $clone->headers['host'] = [$uri->getHost()];
            $clone->headerNames['host'] = 'Host';
        }

        return $clone;
    }
}
