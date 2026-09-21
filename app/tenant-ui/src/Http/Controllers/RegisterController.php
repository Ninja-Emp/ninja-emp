<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;

/**
 * Registers — create, open (with float), close (with count + variance).
 * Mirrors the register / shift entities in the schema.
 */
final class RegisterController extends Controller
{
    public function index(array $params = []): void
    {
        $this->require('pos.use');

        $this->render('registers/index', [
            'title'     => 'Registers',
            'registers' => $this->repo->registers(),
        ]);
    }

    public function create(array $params = []): void
    {
        $this->require('pos.use');
        $this->render('registers/form', [
            'title'    => 'New Register',
            'register' => null,
        ]);
    }

    public function edit(array $params): void
    {
        $this->require('pos.use');
        $register = $this->repo->register($params['id'] ?? '');
        if ($register === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);
            return;
        }
        $this->render('registers/form', [
            'title'    => 'Edit ' . $register['name'],
            'register' => $register,
        ]);
    }

    public function store(array $params = []): void
    {
        $this->require('pos.use');
        $this->repo->saveRegister(null, ['name' => $this->input('name', 'Register')]);
        $this->flash('success', 'Register created.');
        $this->redirect('/registers');
    }

    public function update(array $params): void
    {
        $this->require('pos.use');
        $id = $params['id'] ?? '';
        $this->repo->saveRegister($id, ['name' => $this->input('name', 'Register')]);
        $this->flash('success', 'Register updated.');
        $this->redirect('/registers');
    }

    public function open(array $params): void
    {
        $this->require('pos.use');
        $id = $params['id'] ?? '';
        $float = $this->money('float');
        $this->repo->openRegister($id, $this->input('cashier', 'Cashier'), $float);
        $this->flash('success', 'Register opened with a float of ' . $float . '.');
        $this->redirect('/registers');
    }

    public function close(array $params): void
    {
        $this->require('pos.use');
        $id = $params['id'] ?? '';
        $this->repo->closeRegister($id, $this->money('counted'));
        $this->flash('success', 'Register closed.');
        $this->redirect('/registers');
    }

    private function money(string $key): string
    {
        $raw = preg_replace('/[^0-9.\-]/', '', $this->input($key, '0'));
        return $raw === '' ? '0.0000' : bcadd($raw, '0', 4);
    }
}
