<?php

declare(strict_types=1);

require_once dirname(__DIR__) . '/src/Bootstrap/Autoload.php';

use EmpPos\Http\App;
use EmpPos\Http\Request;
use EmpPos\Shared\Persistence\Database;
use EmpPos\Shared\Persistence\Migrator;

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);
if (!is_string($path) || !str_starts_with($path, '/api/')) {
    header('Content-Type: text/plain; charset=utf-8');
    echo (new EmpPos\Bootstrap\Kernel())->health();
    return;
}

$headers = [];
foreach (getallheaders() ?: [] as $name => $value) {
    $headers[strtolower((string) $name)] = (string) $value;
}
$cookies = [];
foreach ($_COOKIE as $name => $value) {
    if (is_string($value)) {
        $cookies[(string) $name] = $value;
    }
}
$pdo = Database::connectFromEnv();
$app = new App($pdo, new Migrator($pdo, dirname(__DIR__)));
$response = $app->handle(new Request(
    $_SERVER['REQUEST_METHOD'] ?? 'GET',
    $path,
    $headers,
    $cookies,
    (string) file_get_contents('php://input'),
));
http_response_code($response->status());
header('Content-Type: application/json; charset=utf-8');
foreach ($response->cookies() as $cookie) {
    setcookie($cookie['name'], $cookie['value'], [
        'expires' => $cookie['clear'] ? 1 : 0,
        'path' => '/',
        'httponly' => true,
        'samesite' => 'Lax',
    ]);
}
if ($response->body() !== null) {
    echo json_encode($response->body(), JSON_UNESCAPED_SLASHES);
}
