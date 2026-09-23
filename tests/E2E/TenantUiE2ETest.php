<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\E2E;

use PHPUnit\Framework\TestCase;

/**
 * End-to-end acceptance tests for the Tenant UI.
 *
 * These drive the real front controller over HTTP (public/router.php →
 * public/index.php), exercising the router, RBAC gating, views and the JSON
 * endpoints exactly as a browser would. Nothing is stubbed.
 */
final class TenantUiE2ETest extends TestCase
{
    private static AppServer $server;

    public static function setUpBeforeClass(): void
    {
        $root = \dirname(__DIR__, 2);
        self::$server = new AppServer(
            $root . '/apps/tenant-ui/public',
            $root . '/apps/tenant-ui/public/router.php',
        );
        self::$server->start();
    }

    public static function tearDownAfterClass(): void
    {
        self::$server->stop();
    }

    public function testDashboardRendersTheTenant(): void
    {
        $response = self::$server->get('/');

        self::assertSame(200, $response->status);
        self::assertTrue($response->contains('Riverbend Marketplace'), 'dashboard shows the tenant name');
        self::assertTrue($response->contains('Dashboard'), 'dashboard renders its heading');
    }

    public function testPointOfSaleLoads(): void
    {
        $response = self::$server->get('/pos');

        self::assertSame(200, $response->status);
        self::assertTrue($response->contains('Point of Sale'));
    }

    public function testInventoryLoads(): void
    {
        $response = self::$server->get('/inventory');

        self::assertSame(200, $response->status);
        self::assertTrue($response->contains('Inventory'));
    }

    public function testReportsLoadForOwner(): void
    {
        $response = self::$server->get('/reports?role=owner');

        self::assertSame(200, $response->status);
    }

    public function testReportsAreForbiddenForCashier(): void
    {
        $response = self::$server->get('/reports?role=cashier');

        self::assertSame(403, $response->status);
        self::assertTrue($response->contains('Access denied'));
    }

    public function testSettingsAreForbiddenForCashier(): void
    {
        $response = self::$server->get('/settings?role=cashier');

        self::assertSame(403, $response->status);
    }

    public function testPointOfSaleIsAllowedForCashier(): void
    {
        $response = self::$server->get('/pos?role=cashier');

        self::assertSame(200, $response->status);
    }

    public function testUnknownPathReturns404(): void
    {
        $response = self::$server->get('/no-such-page');

        self::assertSame(404, $response->status);
    }

    public function testCheckoutReturnsAReceipt(): void
    {
        $response = self::$server->post('/pos/checkout');

        self::assertSame(200, $response->status);
        $json = $response->json();
        self::assertTrue($json['ok'] === true, 'checkout reports ok');
        self::assertIsString($json['receipt']);
        self::assertStringStartsWith('S-', $json['receipt']);
    }

    public function testScanFindsASeededItemByBarcode(): void
    {
        $response = self::$server->post('/pos/scan', ['code' => '810000000011']);

        self::assertSame(200, $response->status);
        $json = $response->json();
        self::assertTrue($json['ok'] === true, 'scan reports ok');
        self::assertIsArray($json['item']);
        self::assertSame('Blueberry Jam (large jar)', $json['item']['name']);
    }

    public function testScanOfAnUnknownCodeReturns404(): void
    {
        $response = self::$server->post('/pos/scan', ['code' => 'ZZZ-NOPE']);

        self::assertSame(404, $response->status);
        $json = $response->json();
        self::assertTrue($json['ok'] === false, 'scan reports not-ok');
    }

    public function testQuickAddCreatesAnItem(): void
    {
        $response = self::$server->post('/pos/quick-add', [
            'name' => 'E2E Test Widget',
            'price' => '9.99',
            'owner' => 'store',
        ]);

        self::assertSame(200, $response->status);
        $json = $response->json();
        self::assertTrue($json['ok'] === true, 'quick-add reports ok');
        self::assertIsArray($json['item']);
        self::assertSame('E2E Test Widget', $json['item']['name']);
    }

    public function testSettingsRendersAppearanceControls(): void
    {
        $response = self::$server->get('/settings?role=owner');

        self::assertSame(200, $response->status);
        self::assertTrue($response->contains('data-appearance'), 'appearance form is marked for the instant-apply script');
        self::assertTrue($response->contains('name="theme"'), 'theme radios are present');
        self::assertTrue($response->contains('name="mode"'), 'mode radios are present');
        self::assertTrue($response->contains('is-selected'), 'the current theme/mode is marked selected');
    }

    public function testThemeQueryOverrideAppliesToTheShell(): void
    {
        $response = self::$server->get('/settings?role=owner&theme=dark-blue&mode=dark');

        self::assertSame(200, $response->status);
        self::assertTrue($response->contains('data-theme="dark-blue"'), 'the shell reflects the chosen theme');
        self::assertTrue($response->contains('data-mode="dark"'), 'the shell reflects the chosen mode');
    }

    public function testSettingsAppearancePostRedirects(): void
    {
        $response = self::$server->post('/settings', ['theme' => 'dark-blue', 'mode' => 'dark']);

        self::assertSame(302, $response->status);
        self::assertSame('/settings', $response->header('Location'));
    }
}
