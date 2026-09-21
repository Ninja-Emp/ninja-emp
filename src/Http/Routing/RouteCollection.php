<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Routing;

use InvalidArgumentException;
use ReflectionClass;
use ReflectionMethod;

/**
 * Collects routes from controller classes via the #[Route] attribute.
 *
 * A controller is any class; each public method carrying one or more #[Route]
 * attributes becomes one or more routes. This is the attribute-routing seam:
 * adding an endpoint is a matter of annotating a method, never editing a
 * central route file.
 */
final class RouteCollection
{
    /** @var list<array{methods:list<string>,path:string,controller:string,action:string,name:?string,permission:?string,public:bool}> */
    private array $routes = [];

    /**
     * Register every #[Route] method on the given controller class.
     *
     * @param class-string $controller
     */
    public function addController(string $controller): void
    {
        $reflection = new ReflectionClass($controller);

        foreach ($reflection->getMethods(ReflectionMethod::IS_PUBLIC) as $method) {
            if ($method->isStatic() || $method->isConstructor()) {
                continue;
            }

            foreach ($method->getAttributes(Route::class) as $attribute) {
                /** @var Route $route */
                $route = $attribute->newInstance();
                $this->add(
                    $route->methodList(),
                    $route->path,
                    $controller,
                    $method->getName(),
                    $route->name,
                    $route->permission,
                    $route->public,
                );
            }
        }
    }

    /**
     * @param list<string> $methods
     */
    public function add(
        array $methods,
        string $path,
        string $controller,
        string $action,
        ?string $name = null,
        ?string $permission = null,
        bool $public = false
    ): void {
        if ($methods === []) {
            throw new InvalidArgumentException('A route must declare at least one HTTP method.');
        }
        if ($path === '' || $path[0] !== '/') {
            throw new InvalidArgumentException(sprintf('Route path must start with "/": "%s".', $path));
        }

        $this->routes[] = [
            'methods' => $methods,
            'path' => $path,
            'controller' => $controller,
            'action' => $action,
            'name' => $name,
            'permission' => $permission,
            'public' => $public,
        ];
    }

    /**
     * @return list<array{methods:list<string>,path:string,controller:string,action:string,name:?string,permission:?string,public:bool}>
     */
    public function all(): array
    {
        return $this->routes;
    }

    public function count(): int
    {
        return count($this->routes);
    }
}
