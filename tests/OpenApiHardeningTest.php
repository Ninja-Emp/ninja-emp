<?php

declare(strict_types=1);

/**
 * OpenAPI document-builder hardening tests.
 *
 * Targets the branches the primary OpenApiTest does not reach: optional
 * server/tag descriptions, raw-array schemas, skipped reflection members,
 * derived operationIds, root paths, deprecated operations, the full error
 * description table, and JSON encoding flags.
 */

use NinjaEMP\OpenApi\OpenApiDocument;
use NinjaEMP\OpenApi\Schema;
use NinjaEMP\Tests\Support\OpenApiHardeningFixtureController;
use NinjaEMP\Tests\TestHarness;

require_once __DIR__ . '/Support/OpenApiHardeningFixtureController.php';

return static function (TestHarness $t): void {
    $t->suite('OpenAPI (hardening)');

    // ---- server()/tag() omit the description key when blank ----------------
    $doc = new OpenApiDocument('Hardening', '1.0.0');
    $doc->server('https://a.example');
    $doc->server('https://b.example', 'Backup');
    $doc->tag('Core');
    $doc->tag('Extra', 'Extra endpoints.');

    $arr = $doc->toArray();
    $t->assertSame(['url' => 'https://a.example'], $arr['servers'][0], 'server without description omits the key');
    $t->assertSame(['url' => 'https://b.example', 'description' => 'Backup'], $arr['servers'][1], 'server with description keeps it');
    $t->assertSame(['name' => 'Core'], $arr['tags'][0], 'tag without description omits the key');
    $t->assertSame(['name' => 'Extra', 'description' => 'Extra endpoints.'], $arr['tags'][1], 'tag with description keeps it');

    // ---- schema() accepts a raw array as well as a Schema object -----------
    $doc->schema('FromObject', Schema::string());
    $doc->schema('FromArray', ['type' => 'integer']);
    $arr = $doc->toArray();
    $t->assertSame('string', $arr['components']['schemas']['FromObject']['type'], 'Schema object registered');
    $t->assertSame('integer', $arr['components']['schemas']['FromArray']['type'], 'raw array registered verbatim');

    // ---- addController skips constructor, static, and non-route methods ----
    $doc->addController(OpenApiHardeningFixtureController::class);
    $arr = $doc->toArray();

    $t->assertFalse(isset($arr['paths']['/api/ignored-static']), 'static method is skipped');
    $t->assertFalse(isset($arr['paths']['/api/not-a-route']), 'method without #[Route] is skipped');
    $t->assertTrue(isset($arr['paths']['/api/derived/thing']), 'derived route present');
    $t->assertTrue(isset($arr['paths']['/']), 'root path present');

    // ---- operationId derivation -------------------------------------------
    $t->assertSame('get_api_derived_thing', $arr['paths']['/api/derived/thing']['get']['operationId'], 'operationId derived from path');
    $t->assertSame('get_root', $arr['paths']['/']['get']['operationId'], 'root path derives the root slug');

    // ---- bare operation: no ApiSchema, only operationId + responses --------
    $bare = $arr['paths']['/api/bare']['get'];
    $t->assertFalse(isset($bare['summary']), 'bare operation has no summary');
    $t->assertFalse(isset($bare['description']), 'bare operation has no description');
    $t->assertFalse(isset($bare['tags']), 'bare operation has no tags');
    $t->assertFalse(isset($bare['deprecated']), 'bare operation is not deprecated');
    $t->assertFalse(isset($bare['requestBody']), 'bare operation has no request body');
    $t->assertSame('Successful response', $bare['responses']['200']['description'], 'bare operation always has a 200 response');
    $t->assertFalse(isset($bare['responses']['200']['content']), '200 without a response schema has no content');

    // ---- deprecated + description + full error table ----------------------
    $legacy = $arr['paths']['/api/legacy/{id}']['delete'];
    $t->assertSame(true, $legacy['deprecated'], 'deprecated flag surfaced');
    $t->assertSame('Deprecated endpoint.', $legacy['description'], 'operation description surfaced');
    $t->assertSame('Destroy legacy', $legacy['summary'], 'operation summary surfaced');

    $expectedErrors = [
        400 => 'Bad request',
        401 => 'Authentication required',
        403 => 'Access denied',
        404 => 'Not found',
        409 => 'Conflict',
        422 => 'Validation failed',
        500 => 'Error',
    ];
    foreach ($expectedErrors as $code => $description) {
        $t->assertTrue(isset($legacy['responses'][(string) $code]), "declared {$code} response present");
        $t->assertSame($description, $legacy['responses'][(string) $code]['description'], "error description for {$code}");
        $t->assertSame('#/components/schemas/Error', $legacy['responses'][(string) $code]['content']['application/json']['schema']['$ref'], "error {$code} references the Error schema");
    }

    // ---- multiple verbs on one path ---------------------------------------
    $t->assertTrue(isset($arr['paths']['/api/multi']['get']), 'multi path GET present');
    $t->assertTrue(isset($arr['paths']['/api/multi']['post']), 'multi path POST present');

    // ---- toArray filters a blank description ------------------------------
    $noDesc = (new OpenApiDocument('NoDesc', '1.0.0'))->toArray();
    $t->assertFalse(isset($noDesc['info']['description']), 'blank description is filtered out');
    $t->assertSame('NoDesc', $noDesc['info']['title'], 'title always present');

    // ---- empty paths serialize as an object, not an array -----------------
    $empty = (new OpenApiDocument('Empty', '1.0.0'))->toArray();
    $t->assertTrue($empty['paths'] instanceof stdClass, 'empty paths is a stdClass object');

    // ---- toJson preserves slashes and unicode -----------------------------
    $jsonDoc = new OpenApiDocument('JSON', '1.0.0', 'Ünïcode / slashes');
    $json = $jsonDoc->toJson();
    $t->assertTrue(str_contains($json, 'Ünïcode / slashes'), 'toJson keeps unicode and slashes unescaped');
    $t->assertSame(JSON_ERROR_NONE, json_last_error(), 'toJson emits valid JSON');
};
