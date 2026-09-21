<?php

declare(strict_types=1);

namespace Psr\Http\Message;

/**
 * Representation of an incoming, server-side HTTP request (PSR-7, vendored).
 */
interface ServerRequestInterface extends RequestInterface
{
    /** @return array<string, mixed> */
    public function getServerParams(): array;

    /** @return array<string, string> */
    public function getCookieParams(): array;

    public function withCookieParams(array $cookies): static;

    /** @return array<string, mixed> */
    public function getQueryParams(): array;

    public function withQueryParams(array $query): static;

    /** @return array<string, mixed> */
    public function getUploadedFiles(): array;

    public function withUploadedFiles(array $uploadedFiles): static;

    /** @return array<string, mixed>|object|null */
    public function getParsedBody();

    public function withParsedBody($data): static;

    /** @return array<string, mixed> */
    public function getAttributes(): array;

    public function getAttribute(string $name, $default = null);

    public function withAttribute(string $name, $value): static;

    public function withoutAttribute(string $name): static;
}
