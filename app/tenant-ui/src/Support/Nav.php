<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Support;

/**
 * Navigation definition for the sidebar.
 *
 * Each item declares the permission required to see it, so the sidebar is
 * automatically role-aware. Groups keep related modules together.
 */
final class Nav
{
    /**
     * @return list<array{label:string,items:list<array{label:string,path:string,icon:string,permission:string,badge?:string}>}>
     */
    public static function groups(Auth $auth, array $badges = []): array
    {
        $groups = [
            [
                'label' => 'Overview',
                'items' => [
                    ['label' => 'Dashboard', 'path' => '/', 'icon' => 'i-dashboard', 'permission' => 'dashboard.view'],
                ],
            ],
            [
                'label' => 'Operations',
                'items' => [
                    ['label' => 'Point of Sale', 'path' => '/pos', 'icon' => 'i-pos', 'permission' => 'pos.use'],
                    ['label' => 'Booths', 'path' => '/booths', 'icon' => 'i-booth', 'permission' => 'booths.manage'],
                    ['label' => 'Booth Map', 'path' => '/booths/map', 'icon' => 'i-map', 'permission' => 'booths.manage'],
                    ['label' => 'Inventory', 'path' => '/inventory', 'icon' => 'i-inventory', 'permission' => 'inventory.manage'],
                ],
            ],
            [
                'label' => 'Business',
                'items' => [
                    ['label' => 'Vendors', 'path' => '/vendors', 'icon' => 'i-vendor', 'permission' => 'vendors.manage'],
                    ['label' => 'Reports', 'path' => '/reports', 'icon' => 'i-report', 'permission' => 'reports.view'],
                ],
            ],
            [
                'label' => 'System',
                'items' => [
                    ['label' => 'Settings', 'path' => '/settings', 'icon' => 'i-settings', 'permission' => 'settings.manage'],
                ],
            ],
        ];

        // Filter by permission and attach badges.
        $out = [];
        foreach ($groups as $group) {
            $items = [];
            foreach ($group['items'] as $item) {
                if (!$auth->can($item['permission'])) {
                    continue;
                }
                if (isset($badges[$item['path']])) {
                    $item['badge'] = (string) $badges[$item['path']];
                }
                $items[] = $item;
            }
            if ($items !== []) {
                $out[] = ['label' => $group['label'], 'items' => $items];
            }
        }
        return $out;
    }
}
