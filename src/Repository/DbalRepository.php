<?php

declare(strict_types=1);

namespace NinjaEMP\Repository;

use NinjaEMP\Db\Connection;
use NinjaEMP\Db\TenantContext;

/**
 * The real, database-backed implementation of {@see Repository}.
 *
 * It maps the normalized schema (party / party_role / space / lease /
 * inventory_item / consignment_item / register / shift / sale) onto the flat
 * array shapes the tenant UI expects, and delegates every ledger-affecting
 * write to the database's own posting functions (post_sale, receive_inventory,
 * post_shift_close, …). The application layer never re-implements posting: the
 * DB functions are the single source of truth for the ledger (ADR-0020/0028).
 *
 * Every method runs inside Connection::transactional(), because the DBAL sets
 * the tenant search_path and app.tenant_id with SET LOCAL, which requires a
 * transaction (ADR-0025). Reads are transactional too, for the same reason.
 *
 * Money is a 4-dp string end to end. Nothing here produces a float.
 */
final class DbalRepository implements Repository
{
    public function __construct(
        private readonly Connection $conn,
        private readonly TenantContext $context,
    ) {
    }

    // ---- Tenant -----------------------------------------------------------

    public function tenant(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $row = $c->select(
                'SELECT legal_name, functional_currency, timezone FROM tenant_config LIMIT 1'
            )->first();

            if ($row === null) {
                return ['name' => '', 'slug' => $this->slug(), 'currency' => 'USD', 'timezone' => 'UTC'];
            }

            $r = $row->toArray();

            return [
                'name'     => (string) ($r['legal_name'] ?? ''),
                'slug'     => $this->slug(),
                'currency' => (string) ($r['functional_currency'] ?? 'USD'),
                'timezone' => (string) ($r['timezone'] ?? 'UTC'),
            ];
        });
    }

    public function updateTenant(array $fields): void
    {
        $this->conn->transactional(function (Connection $c) use ($fields): void {
            $sets = [];
            $params = [];

            if (isset($fields['name']) && $fields['name'] !== '') {
                $sets[] = 'legal_name = :name';
                $params['name'] = (string) $fields['name'];
            }
            if (isset($fields['currency']) && $fields['currency'] !== '') {
                $sets[] = 'functional_currency = :currency';
                $params['currency'] = strtoupper((string) $fields['currency']);
            }
            if (isset($fields['timezone']) && $fields['timezone'] !== '') {
                $sets[] = 'timezone = :timezone';
                $params['timezone'] = (string) $fields['timezone'];
            }

            if ($sets === []) {
                return;
            }

            $c->execute('UPDATE tenant_config SET ' . implode(', ', $sets), $params);
        });
    }

    // ---- Spaces (booths) --------------------------------------------------

    public function spaces(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $rows = $c->select(self::SPACE_SELECT . ' WHERE s.deleted_at IS NULL GROUP BY ' . self::SPACE_GROUP . ' ORDER BY s.code');

            return array_map(static fn ($row): array => RowMapper::space($row->toArray()), $rows->rows());
        });
    }

    public function space(string $id): ?array
    {
        return $this->conn->transactional(function (Connection $c) use ($id): ?array {
            $row = $c->select(
                self::SPACE_SELECT . ' WHERE s.id = :id AND s.deleted_at IS NULL GROUP BY ' . self::SPACE_GROUP,
                ['id' => $id],
            )->first();

            return $row === null ? null : RowMapper::space($row->toArray());
        });
    }

    public function saveSpace(?string $id, array $fields): string
    {
        return $this->conn->transactional(function (Connection $c) use ($id, $fields): string {
            $code = (string) ($fields['code'] ?? '');
            $name = (string) ($fields['name'] ?? '');
            $type = (string) ($fields['type'] ?? 'inline');
            $sqft = (string) ($fields['sqft'] ?? '0');
            $status = (string) ($fields['status'] ?? 'available');

            if ($id !== null && $id !== '') {
                $c->execute(
                    'UPDATE space SET code = :code, name = :name, space_type_code = :type,
                            area_sqft = :sqft, status = :status
                     WHERE id = :id',
                    ['code' => $code, 'name' => $name, 'type' => $type, 'sqft' => $sqft, 'status' => $status, 'id' => $id],
                );
                $spaceId = $id;
            } else {
                $floorId = (string) ($fields['floor_id'] ?? '');
                if ($floorId === '') {
                    $floorId = (string) $c->scalar('SELECT id FROM floor ORDER BY level_no LIMIT 1');
                }

                $spaceId = (string) $c->scalar(
                    'INSERT INTO space (floor_id, code, name, space_type_code, area_sqft, status)
                     VALUES (:floor, :code, :name, :type, :sqft, :status)
                     RETURNING id',
                    ['floor' => $floorId, 'code' => $code, 'name' => $name, 'type' => $type, 'sqft' => $sqft, 'status' => $status],
                );
            }

            $this->upsertSpaceAttributes($c, $spaceId, $fields);

            if (array_key_exists('vendor_id', $fields)) {
                $this->assignSpaceVendor($c, $spaceId, $fields['vendor_id'] === null ? null : (string) $fields['vendor_id']);
            }

            return $spaceId;
        });
    }

    // ---- Vendors ----------------------------------------------------------

    public function vendors(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $rows = $c->select(
                'SELECT * FROM (' . self::VENDOR_SELECT . ' WHERE p.deleted_at IS NULL) v ORDER BY v.display_name'
            );

            return array_map(static fn ($row): array => RowMapper::vendor($row->toArray()), $rows->rows());
        });
    }

    public function vendor(string $id): ?array
    {
        return $this->conn->transactional(function (Connection $c) use ($id): ?array {
            $row = $c->select(
                'SELECT * FROM (' . self::VENDOR_SELECT . ' WHERE p.deleted_at IS NULL AND p.id = :id) v',
                ['id' => $id],
            )->first();

            return $row === null ? null : RowMapper::vendor($row->toArray());
        });
    }

    public function saveVendor(?string $id, array $fields): string
    {
        return $this->conn->transactional(function (Connection $c) use ($id, $fields): string {
            $name = (string) ($fields['name'] ?? '');
            $type = (string) ($fields['type'] ?? 'vendor');
            $role = $type === 'consignor' ? 'consignor' : 'vendor';
            $rate = bcdiv((string) ($fields['commission'] ?? '0'), '100', 6);
            $status = (string) ($fields['status'] ?? 'active');

            if ($id !== null && $id !== '') {
                $c->execute('UPDATE party SET display_name = :name WHERE id = :id', ['name' => $name, 'id' => $id]);
                $c->execute('UPDATE organization SET legal_name = :name WHERE party_id = :id', ['name' => $name, 'id' => $id]);
                $c->execute(
                    'UPDATE consignor_agreement SET default_commission_rate = :rate, status = :status
                     WHERE consignor_party_id = :id AND deleted_at IS NULL',
                    ['rate' => $rate, 'status' => $status === 'paused' ? 'suspended' : 'active', 'id' => $id],
                );
                $vendorId = $id;
            } else {
                $vendorId = (string) $c->scalar(
                    "INSERT INTO party (party_type, display_name) VALUES ('organization', :name) RETURNING id",
                    ['name' => $name],
                );
                $c->execute(
                    'INSERT INTO organization (party_id, legal_name) VALUES (:id, :name)',
                    ['id' => $vendorId, 'name' => $name],
                );
                $c->execute(
                    'INSERT INTO party_role (party_id, role_type_code) VALUES (:id, :role)',
                    ['id' => $vendorId, 'role' => $role],
                );
                if ($role === 'consignor') {
                    $c->execute(
                        'INSERT INTO consignor_agreement (consignor_party_id, default_commission_rate, status)
                         VALUES (:id, :rate, :status)',
                        ['id' => $vendorId, 'rate' => $rate, 'status' => $status === 'paused' ? 'suspended' : 'active'],
                    );
                }
            }

            $this->upsertContact($c, $vendorId, 'email', (string) ($fields['email'] ?? ''));
            $this->upsertContact($c, $vendorId, 'phone', (string) ($fields['phone'] ?? ''));

            return $vendorId;
        });
    }

    public function purchaseFromVendor(string $vendorId, array $fields): string
    {
        return $this->conn->transactional(function (Connection $c) use ($vendorId, $fields): string {
            $qty = max(1, (int) ($fields['qty'] ?? 1));
            $cost = RowMapper::money($fields['cost'] ?? '0');
            $price = RowMapper::money($fields['price'] ?? $cost);
            $sku = (string) ($fields['sku'] ?? '');
            $name = (string) ($fields['name'] ?? 'Purchased item');
            $category = (string) ($fields['category'] ?? 'General');
            $barcode = (string) ($fields['barcode'] ?? '');
            $currency = (string) ($fields['currency'] ?? 'USD');

            // Insert the item with zero running state; receive_inventory() is the
            // only writer of on_hand / avg_cost (ADR-0031).
            $itemId = (string) $c->scalar(
                'INSERT INTO inventory_item
                   (sku, description, category, supplier_party_id, list_price, barcode,
                    on_hand, avg_cost, currency, reorder_point)
                 VALUES (:sku, :name, :category, :vendor, :price, :barcode, 0, 0, :currency, 0)
                 RETURNING id',
                [
                    'sku' => $sku, 'name' => $name, 'category' => $category, 'vendor' => $vendorId,
                    'price' => $price, 'barcode' => $barcode === '' ? null : $barcode, 'currency' => $currency,
                ],
            );

            // Receipt posts Inventory / AP and updates the moving weighted average.
            $c->scalar(
                'SELECT receive_inventory(:item, :qty, :cost, current_date, :key, true)',
                [
                    'item' => $itemId,
                    'qty'  => (string) $qty,
                    'cost' => $cost,
                    'key'  => 'purchase:' . $itemId,
                ],
            );

            return $itemId;
        });
    }

    // ---- Items ------------------------------------------------------------

    public function items(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $rows = $c->select(self::ITEM_SELECT . ' ORDER BY description');

            return array_map([$this, 'mapItem'], $rows->rows());
        });
    }

    public function item(string $id): ?array
    {
        return $this->conn->transactional(function (Connection $c) use ($id): ?array {
            $row = $c->select(self::ITEM_SELECT . ' AND id = :id', ['id' => $id])->first();

            return $row === null ? null : $this->mapItem($row);
        });
    }

    public function itemByBarcode(string $barcode): ?array
    {
        return $this->conn->transactional(function (Connection $c) use ($barcode): ?array {
            $row = $c->select(
                self::ITEM_SELECT . ' AND (barcode = :code OR sku = :code)',
                ['code' => $barcode],
            )->first();

            return $row === null ? null : $this->mapItem($row);
        });
    }

    public function saveItem(?string $id, array $fields): string
    {
        return $this->conn->transactional(function (Connection $c) use ($id, $fields): string {
            $owner = (string) ($fields['owner'] ?? 'vendor');

            return $owner === 'store'
                ? $this->saveOwnedItem($c, $id, $fields)
                : $this->saveConsignedItem($c, $id, $fields);
        });
    }

    // ---- Sales ------------------------------------------------------------

    public function sales(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $sales = $c->select(self::SALE_SELECT . " AND s.sale_date = current_date ORDER BY s.created_at DESC");

            if ($sales->isEmpty()) {
                return [];
            }

            $ids = array_map(static fn ($row): string => (string) $row->toArray()['id'], $sales->rows());
            $lines = $this->linesForSales($c, $ids);

            $out = [];
            foreach ($sales->rows() as $row) {
                $r = $row->toArray();
                $out[] = RowMapper::sale($r, $lines[(string) $r['id']] ?? []);
            }

            return $out;
        });
    }

    public function salesTrend(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $rows = $c->select(
                "SELECT sale_date, SUM(total) AS amount
                   FROM sale
                  WHERE deleted_at IS NULL
                    AND status IN ('completed','refunded','partially_refunded')
                    AND sale_date >= current_date - 13
                  GROUP BY sale_date
                  ORDER BY sale_date"
            );

            return array_map(static fn ($row): array => RowMapper::trendPoint($row->toArray()), $rows->rows());
        });
    }

    // ---- Registers --------------------------------------------------------

    public function registers(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $rows = $c->select(self::REGISTER_SELECT . ' ORDER BY r.name');

            return array_map(static fn ($row): array => RowMapper::register($row->toArray()), $rows->rows());
        });
    }

    public function register(string $id): ?array
    {
        return $this->conn->transactional(function (Connection $c) use ($id): ?array {
            $row = $c->select(self::REGISTER_SELECT . ' AND r.id = :id', ['id' => $id])->first();

            return $row === null ? null : RowMapper::register($row->toArray());
        });
    }

    public function saveRegister(?string $id, array $fields): string
    {
        return $this->conn->transactional(function (Connection $c) use ($id, $fields): string {
            $name = (string) ($fields['name'] ?? 'Register');
            $code = (string) ($fields['code'] ?? strtoupper(substr(preg_replace('/[^A-Za-z0-9]/', '', $name) ?: 'REG', 0, 8)));

            if ($id !== null && $id !== '') {
                $c->execute('UPDATE register SET name = :name, code = :code WHERE id = :id', ['name' => $name, 'code' => $code, 'id' => $id]);

                return $id;
            }

            return (string) $c->scalar(
                'INSERT INTO register (code, name) VALUES (:code, :name) RETURNING id',
                ['code' => $code, 'name' => $name],
            );
        });
    }

    public function openRegister(string $id, string $cashier, string $float): void
    {
        $this->conn->transactional(function (Connection $c) use ($id, $cashier, $float): void {
            $actor = $this->context->actorId();

            $c->execute(
                'INSERT INTO shift (register_id, opened_by_party_id, opening_float)
                 VALUES (:register, :actor, :float)',
                [
                    'register' => $id,
                    'actor'    => $this->isUuid($actor) ? $actor : null,
                    'float'    => RowMapper::money($float),
                ],
            );
        });
    }

    public function closeRegister(string $id, string $counted): void
    {
        $this->conn->transactional(function (Connection $c) use ($id, $counted): void {
            $shiftId = $c->scalar(
                "SELECT id FROM shift WHERE register_id = :register AND status = 'open' LIMIT 1",
                ['register' => $id],
            );

            if ($shiftId === null) {
                return;
            }

            // post_shift_close() books the over/short and closes the shift.
            $c->scalar(
                'SELECT post_shift_close(:shift, :counted, current_date, :key)',
                [
                    'shift'   => (string) $shiftId,
                    'counted' => RowMapper::money($counted),
                    'key'     => 'shift_close:' . (string) $shiftId,
                ],
            );
        });
    }

    // ---- Tax --------------------------------------------------------------

    public function taxRates(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $rows = $c->select(
                'SELECT tr.id, tr.rate, tj.name AS jurisdiction_name
                   FROM tax_rate tr
                   JOIN tax_jurisdiction tj ON tj.id = tr.jurisdiction_id
                  WHERE tr.effective_thru IS NULL AND tj.deleted_at IS NULL
                  ORDER BY tj.name'
            );

            return array_map(static fn ($row): array => RowMapper::taxRate($row->toArray()), $rows->rows());
        });
    }

    // ---- Derived aggregates ----------------------------------------------

    public function todaySalesTotal(): string
    {
        return $this->conn->transactional(function (Connection $c): string {
            $total = $c->scalar(
                "SELECT COALESCE(SUM(total), 0) FROM sale
                  WHERE deleted_at IS NULL
                    AND status IN ('completed','refunded','partially_refunded')
                    AND sale_date = current_date"
            );

            return RowMapper::money($total);
        });
    }

    public function totalVendorPayable(): string
    {
        return $this->conn->transactional(function (Connection $c): string {
            $total = $c->scalar('SELECT COALESCE(SUM(balance_owed), 0) FROM v_vendor_balance_realtime');

            return RowMapper::money($total);
        });
    }

    public function lowStockCount(): int
    {
        return $this->conn->transactional(function (Connection $c): int {
            $count = $c->scalar(
                'SELECT COUNT(*) FROM inventory_item
                  WHERE deleted_at IS NULL AND is_active
                    AND on_hand <= COALESCE(reorder_point, 0)'
            );

            return RowMapper::int($count);
        });
    }

    public function inventoryValue(): string
    {
        return $this->conn->transactional(function (Connection $c): string {
            $total = $c->scalar(
                'SELECT COALESCE(SUM(avg_cost * on_hand), 0) FROM inventory_item
                  WHERE deleted_at IS NULL AND is_active'
            );

            return RowMapper::money($total);
        });
    }

    public function spaceStatusCounts(): array
    {
        return $this->conn->transactional(function (Connection $c): array {
            $counts = ['available' => 0, 'leased' => 0, 'reserved' => 0, 'maintenance' => 0, 'inactive' => 0];

            $rows = $c->select('SELECT status, COUNT(*) AS n FROM space WHERE deleted_at IS NULL GROUP BY status');
            foreach ($rows->rows() as $row) {
                $r = $row->toArray();
                $counts[(string) $r['status']] = RowMapper::int($r['n']);
            }

            return $counts;
        });
    }

    // ---- Internals --------------------------------------------------------

    /**
     * @param \NinjaEMP\Db\Row $row
     *
     * @return array<string,mixed>
     */
    private function mapItem($row): array
    {
        $r = $row->toArray();

        return ($r['kind'] ?? 'owned') === 'consigned'
            ? RowMapper::consignedItem($r)
            : RowMapper::ownedItem($r);
    }

    /**
     * @param list<string> $ids
     *
     * @return array<string, list<array<string,mixed>>>
     */
    private function linesForSales(Connection $c, array $ids): array
    {
        $rows = $c->select(
            'SELECT sl.sale_id, sl.description, sl.quantity, sl.unit_price,
                    sl.commission_amount, sl.net_to_consignor,
                    COALESCE(sl.consignor_party_id::text, sl.vendor_party_id::text,
                             sl.inventory_item_id::text, sl.consignment_item_id::text, \'\') AS item_ref
               FROM sale_line sl
              WHERE sl.sale_id = ANY(:ids)
              ORDER BY sl.sale_id, sl.line_no',
            ['ids' => $this->uuidArray($ids)],
        );

        $grouped = [];
        foreach ($rows->rows() as $row) {
            $r = $row->toArray();
            $grouped[(string) $r['sale_id']][] = $r;
        }

        return $grouped;
    }

    private function saveOwnedItem(Connection $c, ?string $id, array $fields): string
    {
        $sku = (string) ($fields['sku'] ?? '');
        $name = (string) ($fields['name'] ?? '');
        $category = (string) ($fields['category'] ?? 'General');
        $price = RowMapper::money($fields['price'] ?? '0');
        $reorder = (string) ($fields['reorder'] ?? '0');
        $barcode = (string) ($fields['barcode'] ?? '');
        $vendor = isset($fields['vendor_id']) && $fields['vendor_id'] !== null ? (string) $fields['vendor_id'] : null;

        if ($id !== null && $id !== '') {
            $c->execute(
                'UPDATE inventory_item
                    SET sku = :sku, description = :name, category = :category,
                        list_price = :price, reorder_point = :reorder, barcode = :barcode
                  WHERE id = :id',
                ['sku' => $sku, 'name' => $name, 'category' => $category, 'price' => $price,
                 'reorder' => $reorder, 'barcode' => $barcode === '' ? null : $barcode, 'id' => $id],
            );

            return $id;
        }

        return (string) $c->scalar(
            'INSERT INTO inventory_item
               (sku, description, category, supplier_party_id, list_price, barcode, reorder_point)
             VALUES (:sku, :name, :category, :vendor, :price, :barcode, :reorder)
             RETURNING id',
            ['sku' => $sku, 'name' => $name, 'category' => $category, 'vendor' => $vendor,
             'price' => $price, 'barcode' => $barcode === '' ? null : $barcode, 'reorder' => $reorder],
        );
    }

    private function saveConsignedItem(Connection $c, ?string $id, array $fields): string
    {
        $sku = (string) ($fields['sku'] ?? '');
        $name = (string) ($fields['name'] ?? '');
        $category = (string) ($fields['category'] ?? 'General');
        $price = RowMapper::money($fields['price'] ?? '0');
        $barcode = (string) ($fields['barcode'] ?? '');
        $vendor = isset($fields['vendor_id']) && $fields['vendor_id'] !== null ? (string) $fields['vendor_id'] : null;

        if ($id !== null && $id !== '') {
            $c->execute(
                'UPDATE consignment_item
                    SET sku = :sku, description = :name, category = :category,
                        agreed_price = :price, barcode = :barcode
                  WHERE id = :id',
                ['sku' => $sku, 'name' => $name, 'category' => $category, 'price' => $price,
                 'barcode' => $barcode === '' ? null : $barcode, 'id' => $id],
            );

            return $id;
        }

        $agreementId = $this->agreementFor($c, $vendor);

        return (string) $c->scalar(
            'INSERT INTO consignment_item
               (agreement_id, sku, description, category, agreed_price, barcode, status)
             VALUES (:agreement, :sku, :name, :category, :price, :barcode, \'available\')
             RETURNING id',
            ['agreement' => $agreementId, 'sku' => $sku, 'name' => $name, 'category' => $category,
             'price' => $price, 'barcode' => $barcode === '' ? null : $barcode],
        );
    }

    private function agreementFor(Connection $c, ?string $vendorId): string
    {
        if ($vendorId === null) {
            throw new \InvalidArgumentException('A consigned item requires a consignor (vendor_id).');
        }

        $existing = $c->scalar(
            'SELECT id FROM consignor_agreement WHERE consignor_party_id = :vendor AND deleted_at IS NULL LIMIT 1',
            ['vendor' => $vendorId],
        );

        if ($existing !== null) {
            return (string) $existing;
        }

        return (string) $c->scalar(
            "INSERT INTO consignor_agreement (consignor_party_id, status) VALUES (:vendor, 'active') RETURNING id",
            ['vendor' => $vendorId],
        );
    }

    private function upsertSpaceAttributes(Connection $c, string $spaceId, array $fields): void
    {
        foreach (['x', 'y', 'w', 'h'] as $key) {
            if (!array_key_exists($key, $fields)) {
                continue;
            }

            $c->execute(
                'INSERT INTO space_attribute (space_id, attr_key, attr_value)
                 VALUES (:space, :key, :value)
                 ON CONFLICT (space_id, attr_key) DO UPDATE SET attr_value = EXCLUDED.attr_value',
                ['space' => $spaceId, 'key' => $key, 'value' => (string) $fields[$key]],
            );
        }
    }

    private function assignSpaceVendor(Connection $c, string $spaceId, ?string $vendorId): void
    {
        // End any current allocation.
        $c->execute(
            'UPDATE lease_space SET thru_date = current_date
              WHERE space_id = :space AND thru_date IS NULL',
            ['space' => $spaceId],
        );

        if ($vendorId === null) {
            $c->execute("UPDATE space SET status = 'available' WHERE id = :space", ['space' => $spaceId]);

            return;
        }

        // Reuse an active lease for this lessee, or open one.
        $leaseId = $c->scalar(
            "SELECT id FROM lease
              WHERE lessee_party_id = :vendor AND status = 'active' AND deleted_at IS NULL
              ORDER BY start_date DESC LIMIT 1",
            ['vendor' => $vendorId],
        );

        if ($leaseId === null) {
            $locationId = (string) $c->scalar('SELECT id FROM location ORDER BY code LIMIT 1');
            $leaseId = (string) $c->scalar(
                "INSERT INTO lease (lessee_party_id, location_id, status, start_date)
                 VALUES (:vendor, :location, 'active', current_date) RETURNING id",
                ['vendor' => $vendorId, 'location' => $locationId],
            );
        }

        $c->execute(
            'INSERT INTO lease_space (lease_id, space_id, from_date) VALUES (:lease, :space, current_date)',
            ['lease' => (string) $leaseId, 'space' => $spaceId],
        );

        $c->execute("UPDATE space SET status = 'leased' WHERE id = :space", ['space' => $spaceId]);
    }

    private function upsertContact(Connection $c, string $partyId, string $type, string $value): void
    {
        if ($value === '') {
            return;
        }

        $c->execute(
            'DELETE FROM party_contact_mechanism WHERE party_id = :party AND mechanism_type_code = :type',
            ['party' => $partyId, 'type' => $type],
        );

        $c->execute(
            'INSERT INTO party_contact_mechanism (party_id, mechanism_type_code, value, is_primary)
             VALUES (:party, :type, :value, true)',
            ['party' => $partyId, 'type' => $type, 'value' => $value],
        );
    }

    private function slug(): string
    {
        return (string) preg_replace('/^tenant_/', '', $this->context->schema());
    }

    private function isUuid(?string $value): bool
    {
        return $value !== null
            && preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i', $value) === 1;
    }

    /**
     * Render a PHP list of uuid strings as a PostgreSQL array literal for ANY().
     *
     * @param list<string> $ids
     */
    private function uuidArray(array $ids): string
    {
        $escaped = array_map(static fn (string $id): string => '"' . str_replace('"', '', $id) . '"', $ids);

        return '{' . implode(',', $escaped) . '}';
    }

    // ---- Shared SQL fragments --------------------------------------------

    private const SPACE_SELECT =
        'SELECT s.id, s.code, s.name, s.floor_id, s.space_type_code, s.area_sqft, s.status,
                ls.lessee_party_id AS vendor_id,
                rc.amount AS rent,
                MAX(CASE WHEN sa.attr_key = \'x\' THEN sa.attr_value END) AS x,
                MAX(CASE WHEN sa.attr_key = \'y\' THEN sa.attr_value END) AS y,
                MAX(CASE WHEN sa.attr_key = \'w\' THEN sa.attr_value END) AS w,
                MAX(CASE WHEN sa.attr_key = \'h\' THEN sa.attr_value END) AS h
           FROM space s
           LEFT JOIN lease_space lsp ON lsp.space_id = s.id AND lsp.thru_date IS NULL
           LEFT JOIN lease ls ON ls.id = lsp.lease_id AND ls.status = \'active\' AND ls.deleted_at IS NULL
           LEFT JOIN rent_component rc ON rc.lease_id = ls.id
                AND rc.component_type_code = \'base_rent\' AND rc.effective_thru IS NULL
           LEFT JOIN space_attribute sa ON sa.space_id = s.id';

    private const SPACE_GROUP =
        's.id, s.code, s.name, s.floor_id, s.space_type_code, s.area_sqft, s.status,
         ls.lessee_party_id, rc.amount';

    private const VENDOR_SELECT =
        'SELECT DISTINCT ON (p.id)
                p.id, p.display_name, p.is_active, p.created_at,
                pr.role_type_code,
                ca.status AS agreement_status,
                ca.default_commission_rate,
                ca.start_date AS since,
                COALESCE(vb.balance_owed, 0) AS balance,
                em.value AS email,
                ph.value AS phone,
                COALESCE(NULLIF(TRIM(COALESCE(pe.given_name, \'\') || \' \' || COALESCE(pe.family_name, \'\')), \'\'),
                         o.trading_name, o.legal_name, \'\') AS contact
           FROM party p
           JOIN party_role pr ON pr.party_id = p.id AND pr.thru_date IS NULL
                AND pr.role_type_code IN (\'vendor\', \'consignor\')
           LEFT JOIN consignor_agreement ca ON ca.consignor_party_id = p.id AND ca.deleted_at IS NULL
           LEFT JOIN v_vendor_balance_realtime vb ON vb.party_id = p.id
           LEFT JOIN person pe ON pe.party_id = p.id
           LEFT JOIN organization o ON o.party_id = p.id
           LEFT JOIN LATERAL (
                SELECT value FROM party_contact_mechanism m
                 WHERE m.party_id = p.id AND m.mechanism_type_code = \'email\'
                 ORDER BY m.is_primary DESC, m.created_at LIMIT 1) em ON true
           LEFT JOIN LATERAL (
                SELECT value FROM party_contact_mechanism m
                 WHERE m.party_id = p.id AND m.mechanism_type_code IN (\'phone\', \'mobile\')
                 ORDER BY m.is_primary DESC, m.created_at LIMIT 1) ph ON true
           ORDER BY p.id, (pr.role_type_code = \'consignor\') DESC';

    private const ITEM_SELECT =
        'SELECT * FROM (
            SELECT id, sku, description, category, supplier_party_id, on_hand, avg_cost,
                   list_price, reorder_point, barcode, \'owned\' AS kind
              FROM inventory_item
             WHERE deleted_at IS NULL AND is_active
            UNION ALL
            SELECT ci.id, ci.sku, ci.description, ci.category, ca.consignor_party_id,
                   1 AS on_hand, 0 AS avg_cost, ci.agreed_price AS list_price,
                   0 AS reorder_point, ci.barcode, \'consigned\' AS kind
              FROM consignment_item ci
              JOIN consignor_agreement ca ON ca.id = ci.agreement_id
             WHERE ci.deleted_at IS NULL AND ci.status IN (\'received\', \'available\', \'reserved\')
         ) items
         WHERE 1 = 1';

    private const SALE_SELECT =
        'SELECT s.id, s.sale_no, s.created_at, s.total, s.currency,
                r.name AS register_name,
                (SELECT COALESCE(pe.given_name || \' \' || pe.family_name, \'\')
                   FROM person pe WHERE pe.party_id = s.created_by) AS cashier,
                ARRAY(SELECT DISTINCT tt.code
                        FROM payment p
                        JOIN payment_tender pt ON pt.payment_id = p.id
                        JOIN tender_type tt ON tt.code = pt.tender_type_code
                       WHERE p.sale_id = s.id AND p.status = \'captured\') AS tenders
           FROM sale s
           LEFT JOIN register r ON r.id = s.register_id
          WHERE s.deleted_at IS NULL
            AND s.status IN (\'completed\', \'refunded\', \'partially_refunded\')';

    private const REGISTER_SELECT =
        'SELECT r.id, r.name, r.code,
                sh.id AS shift_id, sh.opened_at, sh.opening_float, sh.counted_cash, sh.over_short,
                (sh.status = \'open\') AS shift_open,
                COALESCE(sh.opening_float, 0) + COALESCE((
                    SELECT SUM(pt.amount)
                      FROM sale s
                      JOIN payment p ON p.sale_id = s.id AND p.status = \'captured\'
                      JOIN payment_tender pt ON pt.payment_id = p.id
                      JOIN tender_type tt ON tt.code = pt.tender_type_code
                     WHERE s.shift_id = sh.id AND tt.settlement_kind = \'cash\' AND NOT s.is_refund
                ), 0) AS drawer,
                (SELECT COALESCE(pe.given_name || \' \' || pe.family_name, \'\')
                   FROM person pe WHERE pe.party_id = sh.opened_by_party_id) AS cashier
           FROM register r
           LEFT JOIN shift sh ON sh.register_id = r.id AND sh.status = \'open\'
          WHERE r.deleted_at IS NULL AND r.is_active';
}
