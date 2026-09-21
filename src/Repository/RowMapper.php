<?php

declare(strict_types=1);

namespace NinjaEMP\Repository;

/**
 * Pure functions that map normalized schema rows onto the flat array shapes the
 * tenant UI expects.
 *
 * These are deliberately free of any database dependency: they take a raw row
 * (associative array of strings, as PDO returns them) and return the UI shape.
 * That makes the whole mapping layer unit-testable without a live PostgreSQL,
 * which is exactly the constraint we are building under.
 *
 * Money is always normalised to a 4-dp string (bcmath, ADR-0002/0025). Counts
 * and square footage are integers. Nothing here ever produces a float.
 */
final class RowMapper
{
    /**
     * Normalise any numeric to a 4-dp money string. Never a float.
     */
    public static function money(mixed $value): string
    {
        if ($value === null || $value === '') {
            return '0.0000';
        }

        return bcadd((string) $value, '0', 4);
    }

    /**
     * Normalise any numeric to an integer (truncating, half-away-from-zero via
     * bcadd at scale 0). Used for counts, quantities, and square footage.
     */
    public static function int(mixed $value): int
    {
        if ($value === null || $value === '') {
            return 0;
        }

        return (int) bcadd((string) $value, '0', 0);
    }

    /**
     * A percent_rate (0..1) as a display percentage string (e.g. 0.20 -> "20.0000").
     */
    public static function percent(mixed $rate): string
    {
        if ($rate === null || $rate === '') {
            return '0.0000';
        }

        return bcmul((string) $rate, '100', 4);
    }

    /**
     * Interpret a PostgreSQL boolean that may arrive as bool, 't'/'f', '1'/'0'.
     */
    public static function bool(mixed $value): bool
    {
        if (is_bool($value)) {
            return $value;
        }

        return in_array((string) $value, ['1', 't', 'true', 'TRUE', 'y', 'yes'], true);
    }

    /**
     * A date/timestamp as a bare YYYY-MM-DD string.
     */
    public static function date(mixed $value): string
    {
        if ($value === null || $value === '') {
            return '';
        }

        return substr((string) $value, 0, 10);
    }

    /**
     * A timestamp as HH:MM (local wall clock as stored).
     */
    public static function time(mixed $value): string
    {
        if ($value === null || $value === '') {
            return '';
        }

        $string = (string) $value;

        if (preg_match('/(\d{2}):(\d{2})/', $string, $m) === 1) {
            return $m[1] . ':' . $m[2];
        }

        return '';
    }

    // ---- Spaces (booths) --------------------------------------------------

    /**
     * @param array<string,mixed> $r space row joined with its x/y/w/h attributes
     *
     * @return array<string,mixed>
     */
    public static function space(array $r): array
    {
        return [
            'id'        => (string) $r['id'],
            'code'      => (string) ($r['code'] ?? ''),
            'name'      => (string) ($r['name'] ?? ''),
            'floor_id'  => (string) ($r['floor_id'] ?? ''),
            'type'      => (string) ($r['space_type_code'] ?? 'inline'),
            'sqft'      => self::int($r['area_sqft'] ?? 0),
            'status'    => (string) ($r['status'] ?? 'available'),
            'vendor_id' => isset($r['vendor_id']) && $r['vendor_id'] !== null ? (string) $r['vendor_id'] : null,
            'rent'      => self::money($r['rent'] ?? 0),
            'x'         => self::int($r['x'] ?? 1),
            'y'         => self::int($r['y'] ?? 1),
            'w'         => self::int($r['w'] ?? 1),
            'h'         => self::int($r['h'] ?? 1),
        ];
    }

    // ---- Vendors ----------------------------------------------------------

    /**
     * @param array<string,mixed> $r party row joined with role/agreement/contacts
     *
     * @return array<string,mixed>
     */
    public static function vendor(array $r): array
    {
        $role = (string) ($r['role_type_code'] ?? 'vendor');
        $agreementStatus = (string) ($r['agreement_status'] ?? '');
        $isActive = self::bool($r['is_active'] ?? true);

        $status = 'active';
        if (!$isActive) {
            $status = 'inactive';
        } elseif ($agreementStatus === 'suspended') {
            $status = 'paused';
        }

        return [
            'id'         => (string) $r['id'],
            'name'       => (string) ($r['display_name'] ?? ''),
            'contact'    => (string) ($r['contact'] ?? ''),
            'email'      => (string) ($r['email'] ?? ''),
            'phone'      => (string) ($r['phone'] ?? ''),
            'type'       => $role === 'consignor' ? 'consignor' : 'vendor',
            'commission' => self::percent($r['default_commission_rate'] ?? 0),
            'balance'    => self::money($r['balance'] ?? 0),
            'status'     => $status,
            'since'      => self::date($r['since'] ?? ($r['created_at'] ?? '')),
        ];
    }

    // ---- Items ------------------------------------------------------------

    /**
     * An owned inventory item (store-owned stock, ADR-0031).
     *
     * @param array<string,mixed> $r
     *
     * @return array<string,mixed>
     */
    public static function ownedItem(array $r): array
    {
        return [
            'id'       => (string) $r['id'],
            'sku'      => (string) ($r['sku'] ?? ''),
            'name'     => (string) ($r['description'] ?? ''),
            'vendor_id' => isset($r['supplier_party_id']) && $r['supplier_party_id'] !== null
                ? (string) $r['supplier_party_id'] : null,
            'category' => (string) ($r['category'] ?? 'General'),
            'price'    => self::money($r['list_price'] ?? 0),
            'cost'     => self::money($r['avg_cost'] ?? 0),
            'on_hand'  => self::int($r['on_hand'] ?? 0),
            'reorder'  => self::int($r['reorder_point'] ?? 0),
            'barcode'  => (string) ($r['barcode'] ?? ''),
            'owner'    => 'store',
        ];
    }

    /**
     * A consigned item (vendor-owned; never inventory-valued).
     *
     * @param array<string,mixed> $r
     *
     * @return array<string,mixed>
     */
    public static function consignedItem(array $r): array
    {
        $status = (string) ($r['status'] ?? 'received');
        $onFloor = in_array($status, ['received', 'available', 'reserved'], true);

        return [
            'id'       => (string) $r['id'],
            'sku'      => (string) ($r['sku'] ?? ''),
            'name'     => (string) ($r['description'] ?? ''),
            'vendor_id' => isset($r['consignor_party_id']) && $r['consignor_party_id'] !== null
                ? (string) $r['consignor_party_id'] : null,
            'category' => (string) ($r['category'] ?? 'General'),
            'price'    => self::money($r['agreed_price'] ?? 0),
            'cost'     => '0.0000',
            'on_hand'  => $onFloor ? 1 : 0,
            'reorder'  => 0,
            'barcode'  => (string) ($r['barcode'] ?? ''),
            'owner'    => 'vendor',
        ];
    }

    // ---- Registers --------------------------------------------------------

    /**
     * @param array<string,mixed> $r register row joined with its open shift
     *
     * @return array<string,mixed>
     */
    public static function register(array $r): array
    {
        $open = self::bool($r['shift_open'] ?? false);

        return [
            'id'       => (string) $r['id'],
            'name'     => (string) ($r['name'] ?? 'Register'),
            'status'   => $open ? 'open' : 'closed',
            'cashier'  => $open ? (string) ($r['cashier'] ?? '') : null,
            'opened'   => $open ? self::time($r['opened_at'] ?? '') : null,
            'drawer'   => self::money($r['drawer'] ?? 0),
            'float'    => self::money($r['opening_float'] ?? 0),
            'counted'  => isset($r['counted_cash']) && $r['counted_cash'] !== null
                ? self::money($r['counted_cash']) : null,
            'variance' => isset($r['over_short']) && $r['over_short'] !== null
                ? self::money($r['over_short']) : null,
        ];
    }

    // ---- Sales ------------------------------------------------------------

    /**
     * @param array<string,mixed>       $r     sale row joined with register/shift
     * @param list<array<string,mixed>> $lines sale_line rows for this sale
     *
     * @return array<string,mixed>
     */
    public static function sale(array $r, array $lines = []): array
    {
        $mappedLines = [];
        foreach ($lines as $line) {
            $mappedLines[] = [
                'item_id'    => (string) ($line['item_ref'] ?? ''),
                'name'       => (string) ($line['description'] ?? ''),
                'qty'        => self::int($line['quantity'] ?? 0),
                'price'      => self::money($line['unit_price'] ?? 0),
                'commission' => self::money($line['commission_amount'] ?? 0),
                'net'        => self::money($line['net_to_consignor'] ?? 0),
            ];
        }

        $tenders = [];
        if (isset($r['tenders']) && is_array($r['tenders'])) {
            $tenders = array_values(array_map('strval', $r['tenders']));
        }

        return [
            'id'       => (string) $r['id'],
            'no'       => 'S-' . (string) ($r['sale_no'] ?? ''),
            'time'     => self::time($r['created_at'] ?? ''),
            'register' => (string) ($r['register_name'] ?? ''),
            'cashier'  => (string) ($r['cashier'] ?? ''),
            'total'    => self::money($r['total'] ?? 0),
            'tenders'  => $tenders,
            'lines'    => $mappedLines,
        ];
    }

    /**
     * A single point on the 14-day sales trend chart.
     *
     * @param array<string,mixed> $r
     *
     * @return array<string,mixed>
     */
    public static function trendPoint(array $r): array
    {
        $date = self::date($r['sale_date'] ?? '');

        return [
            'day'    => self::shortDay($date),
            'amount' => self::money($r['amount'] ?? 0),
        ];
    }

    /**
     * @param array<string,mixed> $r tax_rate row joined with its jurisdiction
     *
     * @return array<string,mixed>
     */
    public static function taxRate(array $r): array
    {
        return [
            'id'   => (string) $r['id'],
            'name' => (string) ($r['jurisdiction_name'] ?? $r['name'] ?? 'Tax'),
            'rate' => self::percent($r['rate'] ?? 0),
        ];
    }

    /**
     * "2026-09-08" -> "Sep 8".
     */
    public static function shortDay(string $date): string
    {
        if ($date === '') {
            return '';
        }

        $ts = strtotime($date);
        if ($ts === false) {
            return $date;
        }

        return date('M j', $ts);
    }
}
