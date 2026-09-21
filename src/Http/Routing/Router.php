<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Routing;

/**
 * Matches an HTTP method + path against a RouteCollection.
 *
 * Paths support `{param}` placeholders (one path segment each). Matching is
 * exact on the trailing slash and case-sensitive on the path, per RFC 3986.
 */
final class Router
{
    public function __construct(private readonly RouteCollection $routes)
    {
    }

    public function match(string $method, string $path): ?RouteMatch
    {
        $method = strtoupper($method);
        $path = $this->normalize($path);

        foreach ($this->routes->all() as $route) {
            if (!in_array($method, $route['methods'], true)) {
                continue;
            }

            $params = $this->matchPath($route['path'], $path);
            if ($params === null) {
                continue;
            }

            return new RouteMatch(
                $route['controller'],
                $route['action'],
                $params,
                $route['name'],
                $route['permission'],
                $route['public'],
            );
        }

        return null;
    }

    /**
     * @return array<string, string>|null
     */
    private function matchPath(string $pattern, string $path): ?array
    {
        $regex = $this->toRegex($pattern);
        if (preg_match($regex, $path, $matches) !== 1) {
            return null;
        }

        $params = [];
        foreach ($matches as $key => $value) {
            if (is_string($key)) {
                $params[$key] = $value;
            }
        }

        return $params;
    }

    private function toRegex(string $pattern): string
    {
        $pattern = $this->normalize($pattern);
        $regex = preg_replace('#\{([a-zA-Z_][a-zA-Z0-9_]*)\}#', '(?P<$1>[^/]+)', $pattern);

        return '#^' . $regex . '$#';
    }

    private function normalize(string $path): string
    {
        $path = '/' . trim($path, '/');

        return $path === '/' ? '/' : rtrim($path, '/');
    }
}
