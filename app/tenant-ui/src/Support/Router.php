<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Support;

/**
 * Minimal path router.
 *
 * Maps a request path to a [ControllerClass, method] pair. Supports simple
 * `{param}` placeholders. Deliberately tiny — the real app uses attribute
 * routing + PSR-15 middleware; this mirrors the shape so the swap is mechanical.
 */
final class Router
{
    /** @var list<array{method:string,pattern:string,handler:array{0:string,1:string}}> */
    private array $routes = [];

    public function get(string $pattern, array $handler): void
    {
        $this->add('GET', $pattern, $handler);
    }

    public function post(string $pattern, array $handler): void
    {
        $this->add('POST', $pattern, $handler);
    }

    private function add(string $method, string $pattern, array $handler): void
    {
        $this->routes[] = ['method' => $method, 'pattern' => $pattern, 'handler' => $handler];
    }

    /**
     * Resolve a path to a handler + params.
     *
     * @return array{handler:array{0:string,1:string},params:array<string,string>}|null
     */
    public function resolve(string $method, string $path): ?array
    {
        $path = '/' . trim($path, '/');
        foreach ($this->routes as $route) {
            if ($route['method'] !== $method) {
                continue;
            }
            $regex = $this->toRegex($route['pattern']);
            if (preg_match($regex, $path, $matches)) {
                $params = [];
                foreach ($matches as $key => $value) {
                    if (!is_int($key)) {
                        $params[$key] = $value;
                    }
                }
                return ['handler' => $route['handler'], 'params' => $params];
            }
        }
        return null;
    }

    private function toRegex(string $pattern): string
    {
        $pattern = '/' . trim($pattern, '/');
        $regex = preg_replace('#\{([a-zA-Z_][a-zA-Z0-9_]*)\}#', '(?P<$1>[^/]+)', $pattern);
        return '#^' . $regex . '$#';
    }
}
