<?php

declare(strict_types=1);

namespace Psr\Http\Message;

/**
 * HTTP messages consist of requests from a client to a server and responses
 * from a server to a client. This interface defines the methods common to
 * each (PSR-7, vendored — no Composer).
 */
interface MessageInterface
{
    public function getProtocolVersion(): string;

    public function withProtocolVersion(string $version): static;

    /** @return array<string, list<string>> */
    public function getHeaders(): array;

    public function hasHeader(string $name): bool;

    /** @return list<string> */
    public function getHeader(string $name): array;

    public function getHeaderLine(string $name): string;

    public function withHeader(string $name, $value): static;

    public function withAddedHeader(string $name, $value): static;

    public function withoutHeader(string $name): static;

    public function getBody(): StreamInterface;

    public function withBody(StreamInterface $body): static;
}
