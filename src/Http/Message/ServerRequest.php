<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use NinjaEMP\Db\Sql\Value;
use Psr\Http\Message\ServerRequestInterface;
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
     * @param array<string, string|list<string>> $headers
     */
    public function __construct(
        string $method,
        UriInterface $uri,
        array $serverParams = [],
        ?string $body = null,
        array $headers = [],
    ) {
        $this->method = strtoupper($method);
        $this->uri = $uri;
        $this->serverParams = $serverParams;
        $this->body = Stream::fromString($body ?? '');

        foreach ($headers as $name => $value) {
            $this->headers[strtolower(Value::str($name))] = $this->normalizeValue($value);
            $this->headerNames[strtolower(Value::str($name))] = Value::str($name);
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
        ?array $cookies = null,
    ): self {
        $server = self::asStringKeyed($server ?? $_SERVER);
        $query = self::asStringKeyed($query ?? $_GET);
        $body = self::asStringKeyed($body ?? $_POST);
        $cookies = self::asStringKeyed($cookies ?? $_COOKIE);

        $method = Value::str($server['REQUEST_METHOD'] ?? 'GET');
        $uri = self::uriFromServer($server);
        $rawBody = Value::str(file_get_contents('php://input'));

        $request = new self($method, $uri, $server, $rawBody, self::headersFromServer($server));
        $request->cookieParams = array_map(static fn (mixed $v): string => Value::str($v), $cookies);
        $request->queryParams = $query;

        $contentType = $request->getHeaderLine('Content-Type');

        if (str_contains($contentType, 'application/json')) {
            $decoded = json_decode($rawBody, true);
            $request->parsedBody = \is_array($decoded) ? self::asStringKeyed($decoded) : null;
        } else {
            $request->parsedBody = $body;
        }

        return $request;
    }

    /**
     * Normalise an arbitrary array to string-keyed form (superglobals and
     * json_decode both yield array<mixed>).
     *
     * @param array<mixed> $input
     *
     * @return array<string, mixed>
     */
    private static function asStringKeyed(array $input): array
    {
        $out = [];

        foreach ($input as $key => $value) {
            $out[Value::str($key)] = $value;
        }

        return $out;
    }

    /**
     * @param array<string, mixed> $server
     */
    private static function uriFromServer(array $server): Uri
    {
        $https = Value::str($server['HTTPS'] ?? '');
        $scheme = ($https !== '' && $https !== 'off') ? 'https' : 'http';
        $host = Value::str($server['HTTP_HOST'] ?? $server['SERVER_NAME'] ?? 'localhost');
        $requestUri = Value::str($server['REQUEST_URI'] ?? '/');

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
            if (!\is_string($key) || !str_starts_with($key, 'HTTP_')) {
                continue;
            }
            $name = str_replace(' ', '-', ucwords(strtolower(str_replace('_', ' ', substr($key, 5)))));
            $headers[$name] = Value::str($value);
        }

        if (isset($server['CONTENT_TYPE'])) {
            $headers['Content-Type'] = Value::str($server['CONTENT_TYPE']);
        }

        if (isset($server['CONTENT_LENGTH'])) {
            $headers['Content-Length'] = Value::str($server['CONTENT_LENGTH']);
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

    /** @param array<mixed> $cookies */
    public function withCookieParams(array $cookies): static
    {
        $clone = clone $this;
        $clone->cookieParams = array_map(
            static fn (mixed $v): string => Value::str($v),
            self::asStringKeyed($cookies),
        );

        return $clone;
    }

    /** @return array<string, mixed> */
    public function getQueryParams(): array
    {
        return $this->queryParams;
    }

    /** @param array<mixed> $query */
    public function withQueryParams(array $query): static
    {
        $clone = clone $this;
        $clone->queryParams = self::asStringKeyed($query);

        return $clone;
    }

    /** @return array<string, mixed> */
    public function getUploadedFiles(): array
    {
        return $this->uploadedFiles;
    }

    /** @param array<mixed> $uploadedFiles */
    public function withUploadedFiles(array $uploadedFiles): static
    {
        $clone = clone $this;
        $clone->uploadedFiles = self::asStringKeyed($uploadedFiles);

        return $clone;
    }

    /** @return array<string, mixed>|object|null */
    public function getParsedBody()
    {
        return $this->parsedBody;
    }

    /** @param mixed $data */
    public function withParsedBody($data): static
    {
        $clone = clone $this;

        if (\is_array($data)) {
            $clone->parsedBody = self::asStringKeyed($data);
        } elseif (\is_object($data)) {
            $clone->parsedBody = $data;
        } else {
            $clone->parsedBody = null;
        }

        return $clone;
    }

    /** @return array<string, mixed> */
    public function getAttributes(): array
    {
        return $this->attributes;
    }

    /**
     * @param mixed $default
     *
     * @return mixed
     */
    public function getAttribute(string $name, $default = null)
    {
        return $this->attributes[$name] ?? $default;
    }

    /** @param mixed $value */
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
