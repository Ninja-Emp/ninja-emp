<?php

declare(strict_types=1);

/**
 * Ninja EMP — API front controller.
 *
 * The API-first surface (OpenAPI 3.1). Every request enters here, is turned into
 * a PSR-7 ServerRequest, and is handled by the HttpKernel with the full
 * middleware stack:
 *
 *   ErrorHandler → Tenant → Auth → [Routing] → RBAC → CSRF → Dispatch
 *
 * Controllers are attribute-routed (#[Route]); dependencies are injected by a
 * tiny PSR-11 container. No framework, no Composer.
 */

use NinjaEmp\Api\Container;
use NinjaEmp\Api\Http\Controllers\HealthController;
use NinjaEmp\Api\Http\Controllers\MeController;
use NinjaEmp\Api\Http\Controllers\OpenApiController;
use NinjaEmp\Api\Http\Controllers\ReportingController;
use NinjaEmp\Api\Http\Controllers\ShiftController;
use NinjaEmp\Api\Http\Controllers\StoredValueController;
use NinjaEmp\Api\Http\Controllers\VendorController;
use NinjaEMP\Auth\Csrf;
use NinjaEMP\Auth\SessionAuth;
use NinjaEMP\Http\ControllerResolver;
use NinjaEMP\Http\Emitter;
use NinjaEMP\Http\ErrorRenderer;
use NinjaEMP\Http\HttpKernel;
use NinjaEMP\Http\Message\ServerRequest;
use NinjaEMP\Http\Middleware\AuthMiddleware;
use NinjaEMP\Http\Middleware\CsrfMiddleware;
use NinjaEMP\Http\Middleware\ErrorHandlerMiddleware;
use NinjaEMP\Http\Middleware\RbacMiddleware;
use NinjaEMP\Http\Middleware\TenantMiddleware;
use NinjaEMP\Http\Routing\RouteCollection;
use NinjaEMP\Http\Routing\Router;
use NinjaEMP\Support\Env;
use NinjaEMP\Tenancy\InMemoryTenantRegistry;
use NinjaEMP\Tenancy\TenantRecord;
use NinjaEMP\Tenancy\TenantResolver;
use Psr\Log\LoggerInterface;

$root = dirname(__DIR__, 3);
require $root . '/vendor/autoload.php';

// Load .env (if present) so configuration is not hard-coded.
Env::load($root . '/.env');

error_reporting(E_ALL);
ini_set('display_errors', '0');
ini_set('log_errors', '1');

$debug = (getenv('NINJA_EMP_DEBUG') === '1');

// ---- Session (for cookie-based auth) --------------------------------------
if (session_status() !== PHP_SESSION_ACTIVE) {
    session_start();
}

// ---- Database (optional; API boots without one) ---------------------------
$connectionFactory = null;
$dsn = getenv('NINJA_EMP_DSN');

if (is_string($dsn) && $dsn !== '') {
    $dbUser = getenv('NINJA_EMP_DB_USER');
    $dbPassword = getenv('NINJA_EMP_DB_PASSWORD');
    $connectionFactory = Container::connectionFactory(
        $dsn,
        is_string($dbUser) && $dbUser !== '' ? $dbUser : 'ninja_emp',
        is_string($dbPassword) ? $dbPassword : '',
    );
}

$container = Container::bootstrap($connectionFactory);

// ---- Tenancy --------------------------------------------------------------
// In production this is backed by the control-plane registry; here we seed an
// in-memory registry so the surface is exercisable without a database.
$registry = new InMemoryTenantRegistry();
$registry->add(
    new TenantRecord('t-demo', 'demo', 'tenant_demo', 'Demo Mall'),
    'demo.ninjaemp.app',
);
$registry->add(
    new TenantRecord('t-demo', 'demo', 'tenant_demo', 'Demo Mall'),
    'localhost',
);
$resolver = new TenantResolver($registry);

// ---- Routes (attribute-discovered) ----------------------------------------
$controllers = [
    HealthController::class,
    MeController::class,
    VendorController::class,
    ReportingController::class,
    ShiftController::class,
    StoredValueController::class,
];

$routes = new RouteCollection();

foreach ($controllers as $controller) {
    $routes->addController($controller);
}

// The OpenAPI controller reflects the other controllers, so it is constructed
// with the list and registered last (it documents itself too).
$container->instance(
    OpenApiController::class,
    new OpenApiController([...$controllers, OpenApiController::class]),
);
$routes->addController(OpenApiController::class);

$kernel = new HttpKernel(new Router($routes), new ControllerResolver($container));

// ---- Middleware stack -----------------------------------------------------
/** @var LoggerInterface $logger */
$logger = $container->get(LoggerInterface::class);
$kernel->pipe(new ErrorHandlerMiddleware(
    new ErrorRenderer($debug),
    $logger,
));
$kernel->pipe(new TenantMiddleware(
    $resolver,
    required: false,
));
$kernel->pipe(new AuthMiddleware(new SessionAuth()));
$kernel->pipeAfterRouting(new RbacMiddleware());
$kernel->pipeAfterRouting(new CsrfMiddleware(new Csrf()));

// ---- Handle + emit --------------------------------------------------------
$request = ServerRequest::fromGlobals();
$response = $kernel->handle($request);
(new Emitter())->emit($response);
