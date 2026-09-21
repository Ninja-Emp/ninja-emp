<?php

declare(strict_types=1);

namespace NinjaEmp\Api;

use NinjaEMP\Db\Connection;
use NinjaEMP\Db\ConnectionFactory;
use NinjaEMP\Db\TenantContext;
use NinjaEMP\Repository\DbalRepository;
use NinjaEMP\Repository\Repository;
use NinjaEMP\Support\Log\NullLogger;
use NinjaEMP\Tenancy\TenantContextHolder;
use Psr\Container\ContainerInterface;
use Psr\Container\NotFoundExceptionInterface;
use Psr\Log\LoggerInterface;
use RuntimeException;

/**
 * A tiny PSR-11 container. Zero dependencies.
 *
 * Services are registered as factories (lazy) or as already-built instances.
 * The container is the seam the ControllerResolver uses to inject dependencies
 * into controllers (e.g. the Repository).
 */
final class Container implements ContainerInterface
{
    /** @var array<string, callable(self): mixed> */
    private array $factories = [];

    /** @var array<string, mixed> */
    private array $instances = [];

    public function set(string $id, callable $factory): void
    {
        $this->factories[$id] = $factory;
    }

    public function instance(string $id, mixed $value): void
    {
        $this->instances[$id] = $value;
    }

    public function has(string $id): bool
    {
        return isset($this->instances[$id]) || isset($this->factories[$id]);
    }

    public function get(string $id)
    {
        if (array_key_exists($id, $this->instances)) {
            return $this->instances[$id];
        }

        if (!isset($this->factories[$id])) {
            throw new class (sprintf('No entry found for "%s".', $id)) extends RuntimeException implements NotFoundExceptionInterface {
            };
        }

        $value = ($this->factories[$id])($this);
        $this->instances[$id] = $value;

        return $value;
    }

    /**
     * Build the default application container.
     *
     * The connection is built lazily from the request-scoped TenantContextHolder,
     * so the repository always talks to the right tenant schema. When no DSN is
     * configured the data endpoints raise a clear error on first use, while the
     * rest of the surface (health, routing) still boots.
     *
     * @param callable(TenantContext): Connection|null $connectionFactory
     */
    public static function bootstrap(?callable $connectionFactory = null): self
    {
        $container = new self();

        $container->instance(LoggerInterface::class, new NullLogger());
        $container->instance(TenantContextHolder::class, new TenantContextHolder());

        $container->set(Connection::class, static function (self $c) use ($connectionFactory): Connection {
            if ($connectionFactory === null) {
                throw new RuntimeException(
                    'No database connection configured. Set NINJA_EMP_DSN to enable data endpoints.'
                );
            }

            return $connectionFactory($c->get(TenantContextHolder::class)->get());
        });

        $container->set(Repository::class, static function (self $c): Repository {
            return new DbalRepository(
                $c->get(Connection::class),
                $c->get(TenantContextHolder::class)->get(),
            );
        });

        return $container;
    }

    /**
     * Convenience: build a connection factory from a DSN + credentials.
     */
    public static function connectionFactory(string $dsn, string $user, string $password): callable
    {
        $factory = new ConnectionFactory($dsn, $user, $password);

        return static fn (TenantContext $context): Connection => $factory->create($context);
    }
}
