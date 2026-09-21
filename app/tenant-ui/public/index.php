<?php
declare(strict_types=1);

/**
 * Ninja EMP — Tenant UI front controller.
 *
 * Every request enters here. It wires the tiny support layer (router, view,
 * auth, theme, money) to the mock data repository and dispatches to a
 * controller. No framework, no dependencies — mirrors the real app's
 * PSR-7/15 + attribute-routing shape so the swap is mechanical.
 */

use NinjaEmp\TenantUi\Data\MockRepository;
use NinjaEmp\TenantUi\Http\Controllers\AuthController;
use NinjaEmp\TenantUi\Http\Controllers\BoothController;
use NinjaEmp\TenantUi\Http\Controllers\DashboardController;
use NinjaEmp\TenantUi\Http\Controllers\InventoryController;
use NinjaEmp\TenantUi\Http\Controllers\PosController;
use NinjaEmp\TenantUi\Http\Controllers\RegisterController;
use NinjaEmp\TenantUi\Http\Controllers\ReportController;
use NinjaEmp\TenantUi\Http\Controllers\SettingsController;
use NinjaEmp\TenantUi\Http\Controllers\VendorController;
use NinjaEmp\TenantUi\Support\Auth;
use NinjaEmp\TenantUi\Support\Flash;
use NinjaEmp\TenantUi\Support\Router;
use NinjaEmp\TenantUi\Support\Theme;
use NinjaEmp\TenantUi\Support\View;

$root = dirname(__DIR__);

// ---- PSR-4 autoloader for NinjaEmp\TenantUi\ -> src/ ----------------------
spl_autoload_register(static function (string $class) use ($root): void {
    $prefix = 'NinjaEmp\\TenantUi\\';
    if (!str_starts_with($class, $prefix)) {
        return;
    }
    $relative = substr($class, strlen($prefix));
    $file = $root . '/src/' . str_replace('\\', '/', $relative) . '.php';
    if (is_file($file)) {
        require $file;
    }
});

// ---- Error reporting: surface everything in dev, log to stderr ------------
error_reporting(E_ALL);
ini_set('display_errors', '0');
ini_set('log_errors', '1');

// ---- Session + flash ------------------------------------------------------
Flash::start();

// ---- Shared services ------------------------------------------------------
$repo = new MockRepository();
$auth = new Auth();
$view = new View($root . '/src/Views');

// ---- Theme + mode (query override -> session -> default) ------------------
$theme = $_GET['theme'] ?? $_SESSION['theme'] ?? Theme::defaultTheme();
$mode  = $_GET['mode']  ?? $_SESSION['mode']  ?? Theme::defaultMode();
if (!Theme::isValidTheme((string) $theme)) {
    $theme = Theme::defaultTheme();
}
if (!Theme::isValidMode((string) $mode)) {
    $mode = Theme::defaultMode();
}
$_SESSION['theme'] = $theme;
$_SESSION['mode']  = $mode;

// ---- Role switching (demo login) ------------------------------------------
if (isset($_GET['role'])) {
    $auth->loginAs((string) $_GET['role']);
    $_SESSION['role'] = $auth->role();
} elseif (isset($_SESSION['role'])) {
    $auth->loginAs((string) $_SESSION['role']);
}

// ---- Values shared with every view ----------------------------------------
$view->share('tenant', $repo->tenant());
$view->share('user', $auth->user());
$view->share('roleLabel', $auth->roleLabel());
$view->share('theme', $theme);
$view->share('mode', $mode);
$view->share('themes', Theme::themes());
$view->share('modes', Theme::modes());
$view->share('flash', Flash::pull());
$view->share('currentPath', '/' . trim((string) parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH), '/'));
$view->share('navGroups', \NinjaEmp\TenantUi\Support\Nav::groups($auth, [
    '/inventory' => $repo->lowStockCount() > 0 ? (string) $repo->lowStockCount() : '',
]));

// ---- Routes ---------------------------------------------------------------
$router = new Router();

$router->get('/', [DashboardController::class, 'index']);

$router->get('/pos', [PosController::class, 'index']);
$router->post('/pos/scan', [PosController::class, 'scan']);
$router->post('/pos/checkout', [PosController::class, 'checkout']);
$router->post('/pos/quick-add', [PosController::class, 'quickAdd']);
$router->post('/pos/buy', [PosController::class, 'buyFromVendor']);

$router->get('/registers', [RegisterController::class, 'index']);
$router->get('/registers/new', [RegisterController::class, 'create']);
$router->post('/registers', [RegisterController::class, 'store']);
$router->get('/registers/{id}/edit', [RegisterController::class, 'edit']);
$router->post('/registers/{id}', [RegisterController::class, 'update']);
$router->post('/registers/{id}/open', [RegisterController::class, 'open']);
$router->post('/registers/{id}/close', [RegisterController::class, 'close']);

$router->get('/booths', [BoothController::class, 'index']);
$router->get('/booths/map', [BoothController::class, 'map']);
$router->get('/booths/new', [BoothController::class, 'create']);
$router->post('/booths', [BoothController::class, 'store']);
$router->get('/booths/{id}', [BoothController::class, 'show']);
$router->post('/booths/{id}', [BoothController::class, 'update']);

$router->get('/vendors', [VendorController::class, 'index']);
$router->get('/vendors/new', [VendorController::class, 'create']);
$router->post('/vendors', [VendorController::class, 'store']);
$router->get('/vendors/{id}/edit', [VendorController::class, 'edit']);
$router->post('/vendors/{id}/purchase', [VendorController::class, 'purchase']);
$router->post('/vendors/{id}', [VendorController::class, 'update']);
$router->get('/vendors/{id}', [VendorController::class, 'show']);

$router->get('/inventory', [InventoryController::class, 'index']);
$router->get('/inventory/new', [InventoryController::class, 'create']);
$router->post('/inventory', [InventoryController::class, 'store']);
$router->get('/inventory/{id}/edit', [InventoryController::class, 'edit']);
$router->post('/inventory/{id}', [InventoryController::class, 'update']);
$router->get('/inventory/{id}', [InventoryController::class, 'show']);

$router->get('/reports', [ReportController::class, 'index']);

$router->get('/settings', [SettingsController::class, 'index']);
$router->post('/settings', [SettingsController::class, 'update']);

$router->get('/login', [AuthController::class, 'login']);
$router->get('/logout', [AuthController::class, 'logout']);

// ---- Dispatch -------------------------------------------------------------
$method = $_SERVER['REQUEST_METHOD'] ?? 'GET';
$path = (string) parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

$match = $router->resolve($method, $path);

if ($match === null) {
    http_response_code(404);
    echo $view->render('errors/404', ['title' => 'Not found']);
    return;
}

[$class, $action] = $match['handler'];
$controller = new $class($repo, $auth, $view);
$controller->{$action}($match['params']);
