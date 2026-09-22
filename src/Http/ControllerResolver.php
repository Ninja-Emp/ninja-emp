<?php

declare(strict_types=1);

namespace NinjaEMP\Http;

use NinjaEMP\Http\Exception\NotFoundException;
use Psr\Container\ContainerInterface;

/**
 * Instantiates a controller for a matched route.
 *
 * If a PSR-11 container is supplied it is asked first (so controllers can take
 * injected dependencies); otherwise the class is instantiated with no
 * constructor arguments. This keeps the kernel usable with or without a
 * container.
 */
final class ControllerResolver
{
    public function __construct(private readonly ?ContainerInterface $container = null)
    {
    }

    /**
     * @param class-string $controller
     */
    public function resolve(string $controller): object
    {
        if ($this->container !== null && $this->container->has($controller)) {
            $instance = $this->container->get($controller);

            if (\is_object($instance)) {
                return $instance;
            }
        }

        if (!class_exists($controller)) {
            throw new NotFoundException(\sprintf('Controller "%s" not found.', $controller));
        }

        return new $controller();
    }
}
