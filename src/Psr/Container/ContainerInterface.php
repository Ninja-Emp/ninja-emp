<?php

declare(strict_types=1);

namespace Psr\Container;

/**
 * Describes the interface of a container that exposes methods to read its
 * entries (PSR-11, vendored).
 */
interface ContainerInterface
{
    /**
     * Finds an entry of the container by its identifier and returns it.
     *
     * @throws NotFoundExceptionInterface  No entry was found for this identifier.
     * @throws ContainerExceptionInterface Error while retrieving the entry.
     */
    public function get(string $id);

    public function has(string $id): bool;
}
