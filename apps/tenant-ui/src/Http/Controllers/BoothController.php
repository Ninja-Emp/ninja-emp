<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEMP\Db\Sql\Value;
use NinjaEmp\TenantUi\Http\Controller;

/**
 * Booths (spaces) — CRUD + 2D map.
 */
final class BoothController extends Controller
{
    /**
     * @param array<string,mixed> $params
     */
    public function index(array $params = []): void
    {
        $this->require('booths.manage');

        $spaces = $this->repo->spaces();
        $vendors = $this->repo->vendors();
        $vendorNames = [];

        foreach ($vendors as $v) {
            $vendorNames[Value::str($v['id'])] = Value::str($v['name']);
        }

        $this->render('booths/index', [
            'title'       => 'Booths',
            'spaces'      => $spaces,
            'vendorNames' => $vendorNames,
            'statusCounts' => $this->repo->spaceStatusCounts(),
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function map(array $params = []): void
    {
        $this->require('booths.manage');

        $vendors = $this->repo->vendors();
        $vendorNames = [];

        foreach ($vendors as $v) {
            $vendorNames[Value::str($v['id'])] = Value::str($v['name']);
        }

        $this->render('booths/map', [
            'title'       => 'Booth Map',
            'spaces'      => $this->repo->spaces(),
            'vendorNames' => $vendorNames,
            'pageScripts' => ['/assets/js/booth-map.js'],
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function create(array $params = []): void
    {
        $this->require('booths.manage');
        $this->render('booths/form', [
            'title'   => 'New Booth',
            'space'   => null,
            'vendors' => $this->repo->vendors(),
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function store(array $params = []): void
    {
        $this->require('booths.manage');
        // Mock persistence — the real app writes to the tenant schema.
        $this->flash('success', 'Booth created (mock). Wire to DBAL to persist.');
        $this->redirect('/booths');
    }

    /**
     * @param array<string,mixed> $params
     */
    public function show(array $params): void
    {
        $this->require('booths.manage');
        $space = $this->repo->space(Value::str($params['id'] ?? ''));

        if ($space === null) {
            http_response_code(404);
            $this->render('errors/404', ['title' => 'Not found']);

            return;
        }
        $vendorId = Value::str($space['vendor_id']);
        $vendor = $vendorId !== '' ? $this->repo->vendor($vendorId) : null;
        $this->render('booths/form', [
            'title'   => 'Booth ' . Value::str($space['code']),
            'space'   => $space,
            'vendor'  => $vendor,
            'vendors' => $this->repo->vendors(),
        ]);
    }

    /**
     * @param array<string,mixed> $params
     */
    public function update(array $params): void
    {
        $this->require('booths.manage');
        $this->flash('success', 'Booth updated (mock).');
        $this->redirect('/booths/' . Value::str($params['id'] ?? ''));
    }
}
