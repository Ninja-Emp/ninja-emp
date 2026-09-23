<?php

declare(strict_types=1);

/**
 * JSON Schema builder + shared component hardening.
 *
 * Mutation testing showed the surviving mutants in Schema were the optional
 * argument branches (format/description/required) and the clone-on-write
 * methods; in Components they were the property arrays. These tests pin the
 * exact array each builder produces and assert the full shape of every shared
 * component schema.
 */

use NinjaEMP\OpenApi\Components;
use NinjaEMP\OpenApi\OpenApiDocument;
use NinjaEMP\OpenApi\Schema;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Schema (hardening)');

    // ---- string(): optional format + description --------------------------
    $t->assertSame(['type' => 'string'], Schema::string()->toArray(), 'string() with no args');
    $t->assertSame(['type' => 'string', 'format' => 'date-time'], Schema::string('date-time')->toArray(), 'string() with format');
    $t->assertSame(['type' => 'string', 'description' => 'x'], Schema::string(description: 'x')->toArray(), 'string() with description');
    $t->assertSame(
        ['type' => 'string', 'format' => 'uuid', 'description' => 'x'],
        Schema::string('uuid', 'x')->toArray(),
        'string() with format and description',
    );

    // ---- scalar builders: description is filtered when null ---------------
    $t->assertSame(['type' => 'integer'], Schema::integer()->toArray(), 'integer() with no description');
    $t->assertSame(['type' => 'integer', 'description' => 'n'], Schema::integer('n')->toArray(), 'integer() with description');
    $t->assertSame(['type' => 'number'], Schema::number()->toArray(), 'number() with no description');
    $t->assertSame(['type' => 'number', 'description' => 'n'], Schema::number('n')->toArray(), 'number() with description');
    $t->assertSame(['type' => 'boolean'], Schema::boolean()->toArray(), 'boolean() with no description');
    $t->assertSame(['type' => 'boolean', 'description' => 'b'], Schema::boolean('b')->toArray(), 'boolean() with description');

    // ---- money(): currency is interpolated into the description -----------
    $usd = Schema::money()->toArray();
    $t->assertSame('string', $usd['type'], 'money is a string');
    $t->assertTrue(str_contains($usd['description'], 'USD'), 'money defaults to USD');
    $eur = Schema::money('EUR')->toArray();
    $t->assertTrue(str_contains($eur['description'], 'EUR'), 'money honours the currency argument');

    // ---- ref() ------------------------------------------------------------
    $t->assertSame(['$ref' => '#/components/schemas/Thing'], Schema::ref('Thing')->toArray(), 'ref points at components');

    // ---- array(): Schema or raw array items, optional description ---------
    $t->assertSame(
        ['type' => 'array', 'items' => ['type' => 'string']],
        Schema::array(Schema::string())->toArray(),
        'array() with a Schema item',
    );
    $t->assertSame(
        ['type' => 'array', 'items' => ['type' => 'integer']],
        Schema::array(['type' => 'integer'])->toArray(),
        'array() with a raw array item',
    );
    $t->assertSame(
        ['type' => 'array', 'items' => ['type' => 'string'], 'description' => 'd'],
        Schema::array(Schema::string(), 'd')->toArray(),
        'array() with a description',
    );

    // ---- object(): Schema or raw properties, optional required/description -
    $t->assertSame(
        ['type' => 'object', 'properties' => ['id' => ['type' => 'string']], 'required' => ['id']],
        Schema::object(['id' => Schema::string()], ['id'])->toArray(),
        'object() with a Schema property and required',
    );
    $t->assertSame(
        ['type' => 'object', 'properties' => ['id' => ['type' => 'integer']]],
        Schema::object(['id' => ['type' => 'integer']])->toArray(),
        'object() with a raw property and no required',
    );
    $t->assertSame(
        ['type' => 'object', 'properties' => [], 'description' => 'd'],
        Schema::object([], [], 'd')->toArray(),
        'object() with a description',
    );

    // ---- enum(): optional description -------------------------------------
    $t->assertSame(['type' => 'string', 'enum' => ['a', 'b']], Schema::enum(['a', 'b'])->toArray(), 'enum() with no description');
    $t->assertSame(
        ['type' => 'string', 'enum' => ['a'], 'description' => 'd'],
        Schema::enum(['a'], 'd')->toArray(),
        'enum() with a description',
    );

    // ---- clone-on-write: the original is untouched ------------------------
    $base = Schema::string();
    $described = $base->withDescription('changed');
    $t->assertSame(['type' => 'string'], $base->toArray(), 'withDescription does not mutate the original');
    $t->assertSame(['type' => 'string', 'description' => 'changed'], $described->toArray(), 'withDescription returns the clone');

    $nullable = $base->nullable();
    $t->assertSame(['type' => 'string'], $base->toArray(), 'nullable does not mutate the original');
    $t->assertSame(['type' => ['string', 'null']], $nullable->toArray(), 'nullable wraps the type in a union');

    // nullable() on a schema with no type falls back to string.
    $t->assertSame(['$ref' => '#/components/schemas/X', 'type' => ['string', 'null']], Schema::ref('X')->nullable()->toArray(), 'nullable on a typeless schema defaults to string');

    $example = $base->withExample('sample');
    $t->assertSame(['type' => 'string'], $base->toArray(), 'withExample does not mutate the original');
    $t->assertSame(['type' => 'string', 'examples' => ['sample']], $example->toArray(), 'withExample sets the examples list');

    // ---- Components: full shape of every shared schema --------------------
    $t->suite('Components (hardening)');

    $doc = new OpenApiDocument('Shared', '1.0.0');
    $returned = Components::register($doc);
    $t->assertSame($doc, $returned, 'register returns the same document');

    $schemas = $doc->toArray()['components']['schemas'];

    // Error envelope.
    $error = $schemas['Error'];
    $t->assertSame(['error'], $error['required'], 'Error requires the error key');
    $t->assertSame('object', $error['properties']['error']['type'], 'Error.error is an object');
    $t->assertSame(['status', 'message'], $error['properties']['error']['required'], 'Error.error requires status and message');
    $t->assertSame('integer', $error['properties']['error']['properties']['status']['type'], 'Error status is an integer');
    $t->assertSame('string', $error['properties']['error']['properties']['message']['type'], 'Error message is a string');
    $t->assertSame('object', $error['properties']['error']['properties']['details']['type'], 'Error details is an object');

    // Tenant.
    $tenant = $schemas['Tenant'];
    $t->assertSame(['id', 'schema'], $tenant['required'], 'Tenant requires id and schema');
    $t->assertSame('string', $tenant['properties']['id']['type'], 'Tenant id is a string');
    $t->assertSame('string', $tenant['properties']['schema']['type'], 'Tenant schema is a string');

    // User.
    $user = $schemas['User'];
    $t->assertSame(['id', 'name', 'role'], $user['required'], 'User requires id, name, role');
    $t->assertSame(['owner', 'manager', 'accountant', 'cashier'], $user['properties']['role']['enum'], 'User role enum');
    $t->assertSame('string', $user['properties']['initials']['type'], 'User initials is a string');

    // Vendor.
    $vendor = $schemas['Vendor'];
    $t->assertSame(['id', 'name'], $vendor['required'], 'Vendor requires id and name');
    $t->assertSame(['active', 'inactive', 'pending'], $vendor['properties']['status']['enum'], 'Vendor status enum');
    $t->assertSame('#/components/schemas/Money', $vendor['properties']['balance']['$ref'], 'Vendor balance references Money');
    $t->assertSame('number', $vendor['properties']['commission_rate']['type'], 'Vendor commission_rate is a number');
    $t->assertSame('string', $vendor['properties']['booth']['type'], 'Vendor booth is a string');

    // VendorList / VendorEnvelope.
    $t->assertSame(['data'], $schemas['VendorList']['required'], 'VendorList requires data');
    $t->assertSame('array', $schemas['VendorList']['properties']['data']['type'], 'VendorList data is an array');
    $t->assertSame('#/components/schemas/Vendor', $schemas['VendorList']['properties']['data']['items']['$ref'], 'VendorList items reference Vendor');
    $t->assertSame('#/components/schemas/Vendor', $schemas['VendorEnvelope']['properties']['data']['$ref'], 'VendorEnvelope data references Vendor');

    // Health.
    $health = $schemas['Health'];
    $t->assertSame(['status', 'service', 'time'], $health['required'], 'Health requires status, service, time');
    $t->assertSame('date-time', $health['properties']['time']['format'], 'Health time is a date-time');

    // Me.
    $me = $schemas['Me'];
    $t->assertSame(['user', 'tenant'], $me['required'], 'Me requires user and tenant');
    $t->assertSame('#/components/schemas/User', $me['properties']['user']['$ref'], 'Me.user references User');
    $t->assertSame('#/components/schemas/Tenant', $me['properties']['tenant']['$ref'], 'Me.tenant references Tenant');
};
