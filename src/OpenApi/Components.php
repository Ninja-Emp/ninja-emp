<?php

declare(strict_types=1);

namespace NinjaEMP\OpenApi;

/**
 * The shared component schemas every Ninja EMP API document includes: the error
 * envelope, money, and the core domain resources. Kept in one place so the
 * contract is consistent across endpoints.
 */
final class Components
{
    /**
     * Register the standard schemas on a document.
     */
    public static function register(OpenApiDocument $doc): OpenApiDocument
    {
        $doc->schema('Error', Schema::object([
            'error' => Schema::object([
                'status' => Schema::integer('HTTP status code.'),
                'message' => Schema::string(description: 'Human-readable error message.'),
                'details' => Schema::object([], description: 'Optional field-level validation errors.'),
            ], ['status', 'message']),
        ], ['error']));

        $doc->schema('Money', Schema::money());

        $doc->schema('Tenant', Schema::object([
            'id' => Schema::string(description: 'Tenant identifier.'),
            'schema' => Schema::string(description: 'PostgreSQL schema name (schema-per-tenant).'),
        ], ['id', 'schema']));

        $doc->schema('User', Schema::object([
            'id' => Schema::string(),
            'name' => Schema::string(),
            'role' => Schema::enum(['owner', 'manager', 'accountant', 'cashier']),
            'initials' => Schema::string(),
        ], ['id', 'name', 'role']));

        $doc->schema('Vendor', Schema::object([
            'id' => Schema::string(),
            'name' => Schema::string(),
            'booth' => Schema::string(description: 'Assigned booth/space code.'),
            'status' => Schema::enum(['active', 'inactive', 'pending']),
            'balance' => Schema::ref('Money'),
            'commission_rate' => Schema::number('Default commission rate (fraction, 0.40 = 40%).'),
        ], ['id', 'name']));

        $doc->schema('VendorList', Schema::object([
            'data' => Schema::array(Schema::ref('Vendor')),
        ], ['data']));

        $doc->schema('VendorEnvelope', Schema::object([
            'data' => Schema::ref('Vendor'),
        ], ['data']));

        $doc->schema('Health', Schema::object([
            'status' => Schema::string(),
            'service' => Schema::string(),
            'time' => Schema::string(format: 'date-time'),
        ], ['status', 'service', 'time']));

        $doc->schema('Me', Schema::object([
            'user' => Schema::ref('User'),
            'tenant' => Schema::ref('Tenant'),
        ], ['user', 'tenant']));

        return $doc;
    }
}
