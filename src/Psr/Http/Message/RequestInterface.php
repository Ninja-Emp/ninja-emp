<?php

declare(strict_types=1);

namespace Psr\Http\Message;

/**
 * Representation of an outgoing, client-side request (PSR-7, vendored).
 */
interface RequestInterface extends MessageInterface
{
    public function getRequestTarget(): string;

    public function withRequestTarget(string $requestTarget): static;

    public function getMethod(): string;

    public function withMethod(string $method): static;

    public function getUri(): UriInterface;

    public function withUri(UriInterface $uri, bool $preserveHost = false): static;
}
