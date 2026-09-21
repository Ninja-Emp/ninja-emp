<?php

declare(strict_types=1);

namespace Psr\Http\Message;

/**
 * Representation of an outgoing, server-side response (PSR-7, vendored).
 */
interface ResponseInterface extends MessageInterface
{
    public function getStatusCode(): int;

    public function withStatus(int $code, string $reasonPhrase = ''): static;

    public function getReasonPhrase(): string;
}
