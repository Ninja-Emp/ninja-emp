<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;
use NinjaEmp\TenantUi\Support\Auth;

/**
 * Auth — mock login/logout. The login screen lets you pick a role to demo RBAC.
 */
final class AuthController extends Controller
{
    public function login(array $params = []): void
    {
        $this->view->setLayout('layout-bare');
        $this->render('auth/login', [
            'title' => 'Sign in',
            'roles' => Auth::roles(),
        ]);
    }

    public function logout(array $params = []): void
    {
        unset($_SESSION['role']);
        $this->flash('info', 'Signed out.');
        $this->redirect('/login');
    }
}
