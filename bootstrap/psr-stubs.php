<?php

declare(strict_types=1);

/**
 * Minimal PSR interface stubs (PSR-3, PSR-7, PSR-11, PSR-15).
 *
 * Ninja EMP's application layer depends on the PSR *interfaces*, not on any
 * concrete package. When Composer is present the real interfaces are loaded from
 * `vendor/`; when it is not, these stubs let the app boot unchanged.
 *
 * This file is only required by `bootstrap/autoload.php` when
 * `vendor/autoload.php` is absent, and every definition is guarded by
 * `interface_exists()` / `class_exists()`, so it can never clash with the real
 * packages.
 *
 * The signatures mirror the published PSR specifications exactly.
 */

namespace Psr\Log {
    if (!interface_exists(LoggerInterface::class)) {
        interface LoggerInterface
        {
            public function emergency(string|\Stringable $message, array $context = []): void;

            public function alert(string|\Stringable $message, array $context = []): void;

            public function critical(string|\Stringable $message, array $context = []): void;

            public function error(string|\Stringable $message, array $context = []): void;

            public function warning(string|\Stringable $message, array $context = []): void;

            public function notice(string|\Stringable $message, array $context = []): void;

            public function info(string|\Stringable $message, array $context = []): void;

            public function debug(string|\Stringable $message, array $context = []): void;

            /**
             * @param mixed $level
             * @param array<mixed> $context
             */
            public function log($level, string|\Stringable $message, array $context = []): void;
        }
    }

    if (!class_exists(LogLevel::class)) {
        final class LogLevel
        {
            public const EMERGENCY = 'emergency';
            public const ALERT = 'alert';
            public const CRITICAL = 'critical';
            public const ERROR = 'error';
            public const WARNING = 'warning';
            public const NOTICE = 'notice';
            public const INFO = 'info';
            public const DEBUG = 'debug';
        }
    }

    if (!class_exists(AbstractLogger::class)) {
        abstract class AbstractLogger implements LoggerInterface
        {
            public function emergency(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::EMERGENCY, $message, $context);
            }

            public function alert(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::ALERT, $message, $context);
            }

            public function critical(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::CRITICAL, $message, $context);
            }

            public function error(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::ERROR, $message, $context);
            }

            public function warning(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::WARNING, $message, $context);
            }

            public function notice(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::NOTICE, $message, $context);
            }

            public function info(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::INFO, $message, $context);
            }

            public function debug(string|\Stringable $message, array $context = []): void
            {
                $this->log(LogLevel::DEBUG, $message, $context);
            }

            /**
             * @param mixed $level
             * @param array<mixed> $context
             */
            abstract public function log($level, string|\Stringable $message, array $context = []): void;
        }
    }
}

namespace Psr\Http\Message {
    if (!interface_exists(StreamInterface::class)) {
        interface StreamInterface
        {
            public function __toString(): string;

            public function close(): void;

            /** @return resource|null */
            public function detach();

            public function getSize(): ?int;

            public function tell(): int;

            public function eof(): bool;

            public function isSeekable(): bool;

            public function seek(int $offset, int $whence = SEEK_SET): void;

            public function rewind(): void;

            public function isWritable(): bool;

            public function write(string $string): int;

            public function isReadable(): bool;

            public function read(int $length): string;

            public function getContents(): string;

            /** @return mixed */
            public function getMetadata(?string $key = null);
        }
    }

    if (!interface_exists(UriInterface::class)) {
        interface UriInterface
        {
            public function getScheme(): string;

            public function getAuthority(): string;

            public function getUserInfo(): string;

            public function getHost(): string;

            public function getPort(): ?int;

            public function getPath(): string;

            public function getQuery(): string;

            public function getFragment(): string;

            public function withScheme(string $scheme): UriInterface;

            public function withUserInfo(string $user, ?string $password = null): UriInterface;

            public function withHost(string $host): UriInterface;

            public function withPort(?int $port): UriInterface;

            public function withPath(string $path): UriInterface;

            public function withQuery(string $query): UriInterface;

            public function withFragment(string $fragment): UriInterface;

            public function __toString(): string;
        }
    }

    if (!interface_exists(MessageInterface::class)) {
        interface MessageInterface
        {
            public function getProtocolVersion(): string;

            public function withProtocolVersion(string $version): MessageInterface;

            /** @return array<string, list<string>> */
            public function getHeaders(): array;

            public function hasHeader(string $name): bool;

            /** @return list<string> */
            public function getHeader(string $name): array;

            public function getHeaderLine(string $name): string;

            /** @param string|list<string> $value */
            public function withHeader(string $name, $value): MessageInterface;

            /** @param string|list<string> $value */
            public function withAddedHeader(string $name, $value): MessageInterface;

            public function withoutHeader(string $name): MessageInterface;

            public function getBody(): StreamInterface;

            public function withBody(StreamInterface $body): MessageInterface;
        }
    }

    if (!interface_exists(RequestInterface::class)) {
        interface RequestInterface extends MessageInterface
        {
            public function getRequestTarget(): string;

            public function withRequestTarget(string $requestTarget): RequestInterface;

            public function getMethod(): string;

            public function withMethod(string $method): RequestInterface;

            public function getUri(): UriInterface;

            public function withUri(UriInterface $uri, bool $preserveHost = false): RequestInterface;
        }
    }

    if (!interface_exists(ServerRequestInterface::class)) {
        interface ServerRequestInterface extends RequestInterface
        {
            /** @return array<string, mixed> */
            public function getServerParams(): array;

            /** @return array<string, string> */
            public function getCookieParams(): array;

            /** @param array<string, string> $cookies */
            public function withCookieParams(array $cookies): ServerRequestInterface;

            /** @return array<string, mixed> */
            public function getQueryParams(): array;

            /** @param array<string, mixed> $query */
            public function withQueryParams(array $query): ServerRequestInterface;

            /** @return array<string, mixed> */
            public function getUploadedFiles(): array;

            /** @param array<string, mixed> $uploadedFiles */
            public function withUploadedFiles(array $uploadedFiles): ServerRequestInterface;

            /** @return null|array<mixed>|object */
            public function getParsedBody();

            /** @param null|array<mixed>|object $data */
            public function withParsedBody($data): ServerRequestInterface;

            /** @return array<string, mixed> */
            public function getAttributes(): array;

            /** @return mixed */
            public function getAttribute(string $name, $default = null);

            /** @param mixed $value */
            public function withAttribute(string $name, $value): ServerRequestInterface;

            public function withoutAttribute(string $name): ServerRequestInterface;
        }
    }

    if (!interface_exists(ResponseInterface::class)) {
        interface ResponseInterface extends MessageInterface
        {
            public function getStatusCode(): int;

            public function withStatus(int $code, string $reasonPhrase = ''): ResponseInterface;

            public function getReasonPhrase(): string;
        }
    }
}

namespace Psr\Http\Server {
    if (!interface_exists(RequestHandlerInterface::class)) {
        interface RequestHandlerInterface
        {
            public function handle(
                \Psr\Http\Message\ServerRequestInterface $request,
            ): \Psr\Http\Message\ResponseInterface;
        }
    }

    if (!interface_exists(MiddlewareInterface::class)) {
        interface MiddlewareInterface
        {
            public function process(
                \Psr\Http\Message\ServerRequestInterface $request,
                RequestHandlerInterface $handler,
            ): \Psr\Http\Message\ResponseInterface;
        }
    }
}

namespace Psr\Container {
    if (!interface_exists(ContainerExceptionInterface::class)) {
        interface ContainerExceptionInterface extends \Throwable
        {
        }
    }

    if (!interface_exists(NotFoundExceptionInterface::class)) {
        interface NotFoundExceptionInterface extends ContainerExceptionInterface
        {
        }
    }

    if (!interface_exists(ContainerInterface::class)) {
        interface ContainerInterface
        {
            /** @return mixed */
            public function get(string $id);

            public function has(string $id): bool;
        }
    }
}
