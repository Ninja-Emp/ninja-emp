<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use Psr\Http\Message\ServerRequestInterface;
use Psr\Http\Message\UploadedFileInterface;
use Psr\Http\Message\UriInterface;

/**
 * A PSR-7 server-side request, with a factory that builds one from PHP's
 * superglobals. Zero dependencies.
 */
final class ServerRequest implements ServerRequestInterface
{
    use MessageTrait;

    private string $method;

    private UriInterface $uri;

    private ?string $requestTarget = null;

    /** @var array<string, mixed> */
    private array $serverParams;

    /** @var array<string, string> */
    private array $cookieParams = [];

    /** @var array<string, mixed> */
    private array $queryParams = [];

    /** @var array<string, mixed> */
    private array $uploadedFiles = [];

    /** @var array<string, mixed>|object|null */
    private $parsedBody;

    /** @var array<string, mixed> */
    private array $attributes = [];

    /**
     * @param array<string, mixed> $serverParams
     */
    public function __construct(
        string $method,
        UriInterface $uri,
        array $serverParams = [],
        ?string $body = null,
        array $headers = []
    ) {
        $this->method = strtoupper($method);
        $this->uri = $uri;
        $this->serverParams = $serverParams;
        $this->body = Stream::fromString($body ?? '');

        foreach ($headers as $name => $value) {
            $this->headers[strtolower((string) $name)] = $this->normalizeValue($value);
            $this->headerNames[strtolower((string) $name)] = (string) $name;
        }
    }

    /**
     * Build a ServerRequest from PHP superglobals.
     *
     * @param array<string, mixed>|null $server
     * @param array<string, mixed>|null $query
     * @param array<string, mixed>|null $body
     * @param array<string, mixed>|null $cookies
     */
    public static function fromGlobals(
        ?array $server = null,
        ?array $query = null,
        ?array $body = null,
        ?array $cookies = null
    ): self {
        $server ??= $_SERVER;
        $query ??= $_GET;
        $body ??= $_POST;
        $cookies ??= $_COOKIE;

        $method = (string) ($server['REQUEST_METHOD'] ?? 'GET');
        $uri = self::uriFromServer($server);
        $rawBody = (string) file_get_contents('php://input');

        $request = new self($method, $uri, $server, $rawBody, self::headersFromServer($server));
        $request->cookieParams = array_map('strval', $cookies);
        $request->queryParams = $query;

        $contentType = $request->getHeaderLine('Content-Type');
        if (str_contains($contentType, 'application/json')) {
            $decoded = json_decode($rawBody, true);
            $request->parsedBody = is_array($decoded) ? $decoded : null;
        } else {
            $request->parsedBody = $body;
        }

        return $request;
    }

    /**
     * @param array<string, mixed> $server
     */
    private static function uriFromServer(array $server): Uri
    {
        $https = (string) ($server['HTTPS'] ?? '');
        $scheme = ($https !== '' && $https !== 'off') ? 'https' : 'http';
        $host = (string) ($server['HTTP_HOST'] ?? $server['SERVER_NAME'] ?? 'localhost');
        $requestUri = (string) ($server['REQUEST_URI'] ?? '/');

        return new Uri($scheme . '://' . $host . $requestUri);
    }

    /**
     * @param array<string, mixed> $server
     *
     * @return array<string, string>
     */
    private static function headersFromServer(array $server): array
    {
        $headers = [];
        foreach ($server as $key => $value) {
            if (!is_string($key) || !str_starts_with($key, 'HTTP_')) {
                continue;
            }
            $name = str_replace(' ', '-', ucwords(strtolower(str_replace('_', ' ', substr($key, 5)))));
            $headers[$name] = (string) $value;
        }
        if (isset($server['CONTENT_TYPE'])) {
            $headers['Content-Type'] = (string) $server['CONTENT_TYPE'];
        }
        if (isset($server['CONTENT_LENGTH'])) {
            $headers['Content-Length'] = (string) $server['CONTENT_LENGTH'];
        }

        return $headers;
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

    /** @return array<string, mixed> */
    public function getServerParams(): array
    {
        return $this->serverParams;
    }

    /** @return array<string, string> */
    public function getCookieParams(): array
    {
        return $this->cookieParams;
    }

    public function withCookieParams(array $cookies): static
    {
        $clone = clone $this;
        $clone->cookieParams = array_map('strval', $cookies);

        return $clone;
    }

    /** @return array<string, mixed> */
    public function getQueryParams(): array
    {
        return $this->queryParams;
    }

    public function withQueryParams(array $query): static
    {
        $clone = clone $this;
        $clone->queryParams = $query;

        return $clone;
    }

    /** @return array<string, mixed> */
    public function getUploadedFiles(): array
    {
        return $this->uploadedFiles;
    }

    public function withUploadedFiles(array $uploadedFiles): static
    {
        $clone = clone $this;
        $clone->uploadedFiles = $uploadedFiles;

        return $clone;
    }

    /** @return array<string, mixed>|object|null */
    public function getParsedBody()
    {
        return $this->parsedBody;
    }

    public function withParsedBody($data): static
    {
        $clone = clone $this;
        $clone->parsedBody = $data;

        return $clone;
    }

    /** @return array<string, mixed> */
    public function getAttributes(): array
    {
        return $this->attributes;
    }

    public function getAttribute(string $name, $default = null)
    {
        return $this->attributes[$name] ?? $default;
    }

    public function withAttribute(string $name, $value): static
    {
        $clone = clone $this;
        $clone->attributes[$name] = $value;

        return $clone;
    }

    public function withoutAttribute(string $name): static
    {
        $clone = clone $this;
        unset($clone->attributes[$name]);

        return $clone;
    }
}
