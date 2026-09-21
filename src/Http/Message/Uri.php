<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use InvalidArgumentException;
use Psr\Http\Message\UriInterface;

/**
 * A PSR-7 URI value object. Immutable, zero dependencies.
 */
final class Uri implements UriInterface
{
    private const DEFAULT_PORTS = ['http' => 80, 'https' => 443];

    private string $scheme = '';

    private string $userInfo = '';

    private string $host = '';

    private ?int $port = null;

    private string $path = '';

    private string $query = '';

    private string $fragment = '';

    public function __construct(string $uri = '')
    {
        if ($uri === '') {
            return;
        }

        $parts = parse_url($uri);
        if ($parts === false) {
            throw new InvalidArgumentException(sprintf('Unable to parse URI: "%s".', $uri));
        }

        $this->scheme = isset($parts['scheme']) ? strtolower($parts['scheme']) : '';
        $this->host = isset($parts['host']) ? strtolower($parts['host']) : '';
        $this->port = $parts['port'] ?? null;
        $this->path = $parts['path'] ?? '';
        $this->query = $parts['query'] ?? '';
        $this->fragment = $parts['fragment'] ?? '';

        if (isset($parts['user'])) {
            $this->userInfo = $parts['user'];
            if (isset($parts['pass'])) {
                $this->userInfo .= ':' . $parts['pass'];
            }
        }
    }

    public function getScheme(): string
    {
        return $this->scheme;
    }

    public function getAuthority(): string
    {
        if ($this->host === '') {
            return '';
        }

        $authority = $this->host;
        if ($this->userInfo !== '') {
            $authority = $this->userInfo . '@' . $authority;
        }
        if ($this->port !== null) {
            $authority .= ':' . $this->port;
        }

        return $authority;
    }

    public function getUserInfo(): string
    {
        return $this->userInfo;
    }

    public function getHost(): string
    {
        return $this->host;
    }

    public function getPort(): ?int
    {
        if ($this->port === null) {
            return null;
        }
        if (isset(self::DEFAULT_PORTS[$this->scheme]) && self::DEFAULT_PORTS[$this->scheme] === $this->port) {
            return null;
        }

        return $this->port;
    }

    public function getPath(): string
    {
        return $this->path;
    }

    public function getQuery(): string
    {
        return $this->query;
    }

    public function getFragment(): string
    {
        return $this->fragment;
    }

    public function withScheme(string $scheme): static
    {
        $clone = clone $this;
        $clone->scheme = strtolower($scheme);

        return $clone;
    }

    public function withUserInfo(string $user, ?string $password = null): static
    {
        $clone = clone $this;
        $clone->userInfo = $user;
        if ($password !== null) {
            $clone->userInfo .= ':' . $password;
        }

        return $clone;
    }

    public function withHost(string $host): static
    {
        $clone = clone $this;
        $clone->host = strtolower($host);

        return $clone;
    }

    public function withPort(?int $port): static
    {
        if ($port !== null && ($port < 0 || $port > 65535)) {
            throw new InvalidArgumentException('Port must be between 0 and 65535.');
        }
        $clone = clone $this;
        $clone->port = $port;

        return $clone;
    }

    public function withPath(string $path): static
    {
        $clone = clone $this;
        $clone->path = $path;

        return $clone;
    }

    public function withQuery(string $query): static
    {
        $clone = clone $this;
        $clone->query = ltrim($query, '?');

        return $clone;
    }

    public function withFragment(string $fragment): static
    {
        $clone = clone $this;
        $clone->fragment = ltrim($fragment, '#');

        return $clone;
    }

    public function __toString(): string
    {
        $uri = '';
        if ($this->scheme !== '') {
            $uri .= $this->scheme . ':';
        }
        $authority = $this->getAuthority();
        if ($authority !== '') {
            $uri .= '//' . $authority;
        }
        $uri .= $this->path;
        if ($this->query !== '') {
            $uri .= '?' . $this->query;
        }
        if ($this->fragment !== '') {
            $uri .= '#' . $this->fragment;
        }

        return $uri;
    }
}
