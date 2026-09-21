<?php

declare(strict_types=1);

namespace Psr\Http\Message;

/**
 * Value object representing a file uploaded through an HTTP request (PSR-7).
 */
interface UploadedFileInterface
{
    public function getStream(): StreamInterface;

    public function moveTo(string $targetPath): void;

    public function getSize(): ?int;

    public function getError(): int;

    public function getClientFilename(): ?string;

    public function getClientMediaType(): ?string;
}
