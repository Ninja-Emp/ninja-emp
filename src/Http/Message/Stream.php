<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use Psr\Http\Message\StreamInterface;
use RuntimeException;

/**
 * A PSR-7 stream backed by a PHP stream resource. Zero dependencies.
 */
final class Stream implements StreamInterface
{
    /** @var resource|null */
    private $resource;

    private ?int $size = null;

    private bool $seekable;

    private bool $readable;

    private bool $writable;

    /**
     * @param resource $resource
     */
    private function __construct($resource)
    {
        $meta = stream_get_meta_data($resource);
        $this->resource = $resource;
        $this->seekable = (bool) ($meta['seekable'] ?? false);
        $mode = (string) ($meta['mode'] ?? '');
        $this->readable = str_contains($mode, 'r') || str_contains($mode, '+');
        $this->writable = str_contains($mode, 'w') || str_contains($mode, '+')
            || str_contains($mode, 'a') || str_contains($mode, 'x') || str_contains($mode, 'c');
    }

    /** Create a stream from a string. */
    public static function fromString(string $content = ''): self
    {
        $resource = fopen('php://temp', 'r+');
        if ($resource === false) {
            throw new RuntimeException('Unable to open a temporary stream.');
        }
        if ($content !== '') {
            fwrite($resource, $content);
            rewind($resource);
        }

        return new self($resource);
    }

    /** Create a stream from an existing resource. */
    public static function fromResource($resource): self
    {
        return new self($resource);
    }

    public function __toString(): string
    {
        if ($this->resource === null) {
            return '';
        }
        if ($this->seekable) {
            $this->rewind();
        }

        return $this->getContents();
    }

    public function close(): void
    {
        if ($this->resource !== null) {
            fclose($this->resource);
        }
        $this->resource = null;
        $this->size = null;
    }

    public function detach()
    {
        $resource = $this->resource;
        $this->resource = null;
        $this->size = null;

        return $resource;
    }

    public function getSize(): ?int
    {
        if ($this->resource === null) {
            return null;
        }
        if ($this->size !== null) {
            return $this->size;
        }
        $stats = fstat($this->resource);
        if ($stats !== false && isset($stats['size'])) {
            $this->size = (int) $stats['size'];
        }

        return $this->size;
    }

    public function tell(): int
    {
        $this->assertAttached();
        $position = ftell($this->resource);
        if ($position === false) {
            throw new RuntimeException('Unable to determine stream position.');
        }

        return $position;
    }

    public function eof(): bool
    {
        return $this->resource === null || feof($this->resource);
    }

    public function isSeekable(): bool
    {
        return $this->seekable;
    }

    public function seek(int $offset, int $whence = SEEK_SET): void
    {
        $this->assertAttached();
        if (!$this->seekable) {
            throw new RuntimeException('Stream is not seekable.');
        }
        if (fseek($this->resource, $offset, $whence) !== 0) {
            throw new RuntimeException('Unable to seek in stream.');
        }
    }

    public function rewind(): void
    {
        $this->seek(0);
    }

    public function isWritable(): bool
    {
        return $this->writable;
    }

    public function write(string $string): int
    {
        $this->assertAttached();
        if (!$this->writable) {
            throw new RuntimeException('Stream is not writable.');
        }
        $written = fwrite($this->resource, $string);
        if ($written === false) {
            throw new RuntimeException('Unable to write to stream.');
        }
        $this->size = null;

        return $written;
    }

    public function isReadable(): bool
    {
        return $this->readable;
    }

    public function read(int $length): string
    {
        $this->assertAttached();
        if (!$this->readable) {
            throw new RuntimeException('Stream is not readable.');
        }
        if ($length < 0) {
            throw new RuntimeException('Length must be non-negative.');
        }
        if ($length === 0) {
            return '';
        }
        $data = fread($this->resource, $length);
        if ($data === false) {
            throw new RuntimeException('Unable to read from stream.');
        }

        return $data;
    }

    public function getContents(): string
    {
        $this->assertAttached();
        $contents = stream_get_contents($this->resource);
        if ($contents === false) {
            throw new RuntimeException('Unable to read stream contents.');
        }

        return $contents;
    }

    public function getMetadata(?string $key = null)
    {
        if ($this->resource === null) {
            return $key === null ? [] : null;
        }
        $meta = stream_get_meta_data($this->resource);

        return $key === null ? $meta : ($meta[$key] ?? null);
    }

    private function assertAttached(): void
    {
        if ($this->resource === null) {
            throw new RuntimeException('Stream is detached.');
        }
    }
}
