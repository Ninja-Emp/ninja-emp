<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http\Controllers;

use NinjaEmp\TenantUi\Http\Controller;

/**
 * Point of Sale — the priority surface.
 *
 * Barcode scanning, split payments, hold/resume, discounts, tax-free toggle.
 * The cart lives client-side (js/pos.js) for speed; this controller provides
 * the catalog, tenders, tax rates, and the checkout endpoint (mock posting).
 */
final class PosController extends Controller
{
    /** Tender types mirror ADR-0029. */
    private const TENDERS = [
        ['id' => 'cash',             'label' => 'Cash',                 'icon' => 'i-wallet'],
        ['id' => 'check',            'label' => 'Check',                'icon' => 'i-receipt'],
        ['id' => 'card',             'label' => 'Card (clearing)',      'icon' => 'i-wallet'],
        ['id' => 'gift_certificate', 'label' => 'Gift Certificate',     'icon' => 'i-tag'],
        ['id' => 'store_credit',     'label' => 'Customer Store Credit','icon' => 'i-user'],
        ['id' => 'vendor_draw',      'label' => 'Vendor Payable Draw',  'icon' => 'i-vendor'],
    ];

    public function index(array $params = []): void
    {
        $this->require('pos.use');

        $this->render('pos/index', [
            'title'     => 'Point of Sale',
            'items'     => $this->repo->items(),
            'vendors'   => $this->repo->vendors(),
            'tenders'   => self::TENDERS,
            'taxRates'  => $this->repo->taxRates(),
            'registers' => $this->repo->registers(),
            'pageScripts' => ['/assets/js/pos.js'],
        ]);
    }

    /** Barcode/SKU lookup endpoint (JSON). */
    public function scan(array $params = []): void
    {
        $this->require('pos.use');
        header('Content-Type: application/json');

        $code = $this->input('code');
        $item = $code !== '' ? $this->repo->itemByBarcode($code) : null;

        if ($item === null) {
            http_response_code(404);
            echo json_encode(['ok' => false, 'error' => 'No item matches that code.']);
            return;
        }
        echo json_encode(['ok' => true, 'item' => $item]);
    }

    /** Checkout endpoint (mock posting). */
    public function checkout(array $params = []): void
    {
        $this->require('pos.use');
        header('Content-Type: application/json');

        // In the real app this posts a balanced journal entry (ADR-0020/0029).
        // Here we acknowledge and return a receipt number.
        $no = 'S-' . random_int(1047, 9999);
        echo json_encode(['ok' => true, 'receipt' => $no]);
    }
}
