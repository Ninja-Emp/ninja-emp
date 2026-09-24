<?php

declare(strict_types=1);

namespace EmpPos\Http;

final class Response
{
    /**
     * @param array<string, mixed>|null $body
     * @param list<array{name: string, value: string, clear: bool}> $cookies
     */
    public function __construct(
        private readonly int $status,
        private readonly ?array $body,
        private readonly array $cookies = [],
    ) {
    }

    public function status(): int
    {
        return $this->status;
    }

    /**
     * @return array<string, mixed>|null
     */
    public function body(): ?array
    {
        return $this->body;
    }

    /**
     * @return list<array{name: string, value: string, clear: bool}>
     */
    public function cookies(): array
    {
        return $this->cookies;
    }

    /**
     * @param array<string, mixed> $body
     * @param list<array{name: string, value: string, clear: bool}> $cookies
     */
    public static function json(int $status, array $body, array $cookies = []): self
    {
        return new self($status, $body, $cookies);
    }

    /**
     * @param list<array{name: string, value: string, clear: bool}> $cookies
     */
    public static function empty(int $status, array $cookies = []): self
    {
        return new self($status, null, $cookies);
    }
}
