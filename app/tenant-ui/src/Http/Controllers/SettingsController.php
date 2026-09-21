<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;
use NinjaEmp\TenantUi\Support\Auth;
use NinjaEmp\TenantUi\Support\Theme;

/**
 * Settings — appearance (theme/mode), roles & permissions, tenant config.
 */
final class SettingsController extends Controller
{
    public function index(array $params = []): void
    {
        $this->require('settings.manage');

        $this->render('settings/index', [
            'title'       => 'Settings',
            'themes'      => Theme::themes(),
            'modes'       => Theme::modes(),
            'roles'       => Auth::roles(),
            'permissions' => $this->permissionMatrix(),
        ]);
    }

    public function update(array $params = []): void
    {
        $this->require('settings.manage');

        $theme = $this->input('theme');
        $mode = $this->input('mode');
        if (Theme::isValidTheme($theme)) {
            $_SESSION['theme'] = $theme;
        }
        if (Theme::isValidMode($mode)) {
            $_SESSION['mode'] = $mode;
        }
        $this->flash('success', 'Preferences saved.');
        $this->redirect('/settings');
    }

    /**
     * Build the role → permission matrix for display.
     * @return array{permissions:list<string>,roles:array<string,array<string,bool>>}
     */
    private function permissionMatrix(): array
    {
        $permissions = [
            'dashboard.view', 'pos.use', 'booths.manage', 'vendors.manage',
            'inventory.manage', 'reports.view', 'settings.manage', 'accounting.view',
        ];
        $matrix = [];
        foreach (array_keys(Auth::roles()) as $role) {
            $probe = new Auth();
            $probe->loginAs($role);
            foreach ($permissions as $perm) {
                $matrix[$role][$perm] = $probe->can($perm);
            }
        }
        return ['permissions' => $permissions, 'roles' => $matrix];
    }
}
