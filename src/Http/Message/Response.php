<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use NinjaEMP\Db\Sql\Value;

use Psr\Http\Message\ResponseInterface;

/**
 * A PSR-7 server-side response.
 */
final class Response implements ResponseInterface
{
    use MessageTrait;

    private const REASONS = [
        200 => 'OK',
        201 => 'Created',
        202 => 'Accepted',
        204 => 'No Content',
        301 => 'Moved Permanently',
        302 => 'Found',
        303 => 'See Other',
        304 => 'Not Modified',
        307 => 'Temporary Redirect',
        308 => 'Permanent Redirect',
        400 => 'Bad Request',
        401 => 'Unauthorized',
        403 => 'Forbidden',
        404 => 'Not Found',
        405 => 'Method Not Allowed',
        409 => 'Conflict',
        410 => 'Gone',
        415 => 'Unsupported Media Type',
        422 => 'Unprocessable Entity',
        429 => 'Too Many Requests',
        500 => 'Internal Server Error',
        502 => 'Bad Gateway',
        503 => 'Service Unavailable',
    ];

    private int $statusCode;

    private string $reasonPhrase;

    /** @param array<string, string|list<string>> $headers */
    public function __construct(
        int $status = 200,
        ?string $body = null,
        array $headers = [],
        string $reason = '',
    ) {
        $this->statusCode = $status;
        $this->reasonPhrase = $reason;
        $this->body = Stream::fromString($body ?? '');

        foreach ($headers as $name => $value) {
            $this->headers[strtolower(Value::str($name))] = $this->normalizeValue($value);
            $this->headerNames[strtolower(Value::str($name))] = Value::str($name);
        }
    }

    public function getStatusCode(): int
    {
        return $this->statusCode;
    }

    public function withStatus(int $code, string $reasonPhrase = ''): static
    {
        $clone = clone $this;
        $clone->statusCode = $code;
        $clone->reasonPhrase = $reasonPhrase;

        return $clone;
    }

    public function getReasonPhrase(): string
    {
        if ($this->reasonPhrase !== '') {
            return $this->reasonPhrase;
        }

        return self::REASONS[$this->statusCode] ?? '';
    }
}
