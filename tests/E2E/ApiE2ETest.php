<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\E2E;

use PHPUnit\Framework\TestCase;

/**
 * End-to-end acceptance tests for the API surface.
 *
 * Boots the real API front controller (public/router.php → public/index.php)
 * with the full middleware stack (ErrorHandler → Tenant → Auth → Routing →
 * RBAC → CSRF → Dispatch) and asserts the observable contract.
 */
final class ApiE2ETest extends TestCase
{
    private static AppServer $server;

    public static function setUpBeforeClass(): void
    {
        $root = \dirname(__DIR__, 2);
        self::$server = new AppServer(
            $root . '/app/api/public',
            $root . '/app/api/public/router.php',
        );
        self::$server->start();
    }

    public static function tearDownAfterClass(): void
    {
        self::$server->stop();
    }

    public function testHealthIsPublic(): void
    {
        $response = self::$server->get('/api/health');

        self::assertSame(200, $response->status);
        $json = $response->json();
        self::assertSame('ok', $json['status']);
        self::assertSame('ninja-emp-api', $json['service']);
    }

    public function testOpenApiDocumentIsServed(): void
    {
        $response = self::$server->get('/api/openapi.json');

        self::assertSame(200, $response->status);
        $json = $response->json();
        self::assertSame('3.1.0', $json['openapi']);
        self::assertIsArray($json['paths']);
        self::assertArrayHasKey('/api/health', $json['paths']);
    }

    public function testMeRequiresAuthentication(): void
    {
        $response = self::$server->get('/api/me');

        self::assertSame(401, $response->status);
    }

    public function testUnknownApiPathReturns404(): void
    {
        $response = self::$server->get('/api/does-not-exist');

        self::assertSame(404, $response->status);
    }
}
