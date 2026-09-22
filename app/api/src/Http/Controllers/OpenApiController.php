<?php

declare(strict_types=1);

namespace NinjaEmp\Api\Http\Controllers;

use NinjaEMP\Http\Message\Response;
use NinjaEMP\Http\Routing\Route;
use NinjaEMP\OpenApi\ApiSchema;
use NinjaEMP\OpenApi\Components;
use NinjaEMP\OpenApi\OpenApiDocument;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use NinjaEMP\Db\Sql\Value;

/**
 * Serves the generated OpenAPI 3.1 contract and a minimal HTML explorer.
 *
 * The document is built from the same #[Route]/#[ApiSchema] attributes the
 * kernel dispatches, so it is always in sync with the implementation.
 */
final class OpenApiController
{
    /**
     * @param list<class-string> $controllers
     */
    public function __construct(private readonly array $controllers)
    {
    }

    /**
     * @param array<string,mixed> $params
     */
    #[Route('GET', '/api/openapi.json', name: 'openapi.json', public: true)]
    #[ApiSchema(summary: 'OpenAPI 3.1 document', tags: ['System'])]
    public function document(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $json = $this->build()->toJson();

        return new Response(200, $json, ['Content-Type' => 'application/json; charset=utf-8']);
    }

    /**
     * @param array<string,mixed> $params
     */
    #[Route('GET', '/api/docs', name: 'openapi.docs', public: true)]
    #[ApiSchema(summary: 'API explorer', tags: ['System'])]
    public function docs(ServerRequestInterface $request, array $params): ResponseInterface
    {
        $doc = $this->build()->toArray();
        $html = $this->renderExplorer($doc);

        return new Response(200, $html, ['Content-Type' => 'text/html; charset=utf-8']);
    }

    private function build(): OpenApiDocument
    {
        $doc = new OpenApiDocument(
            'Ninja EMP API',
            '1.0.0',
            'Vendor mall + consignment SaaS. Double-entry accounting, API-first.',
        );
        $doc->server('/', 'Current host');
        $doc->tag('System', 'Health, identity and the contract itself.');
        $doc->tag('Vendors', 'Vendor (party) management.');

        Components::register($doc);

        foreach ($this->controllers as $controller) {
            $doc->addController($controller);
        }

        return $doc;
    }

    /**
     * @param array<string, mixed> $doc
     */
    private function renderExplorer(array $doc): string
    {
        /** @var array<string, mixed> $info */
        $info = \is_array($doc['info'] ?? null) ? $doc['info'] : [];
        $title = htmlspecialchars(Value::str($info['title'] ?? 'API'), ENT_QUOTES);
        $version = htmlspecialchars(Value::str($info['version'] ?? ''), ENT_QUOTES);
        $description = htmlspecialchars(Value::str($info['description'] ?? ''), ENT_QUOTES);

        $rows = '';
        /** @var array<string, array<string, mixed>> $paths */
        $paths = \is_array($doc['paths'] ?? null) ? $doc['paths'] : [];
        ksort($paths);

        foreach ($paths as $path => $operations) {
            foreach ($operations as $method => $op) {
                /** @var array<string, mixed> $op */
                $m = strtoupper((string) $method);
                $summary = htmlspecialchars(Value::str($op['summary'] ?? ''), ENT_QUOTES);
                $opId = htmlspecialchars(Value::str($op['operationId'] ?? ''), ENT_QUOTES);
                $secured = isset($op['security']) ? '🔒' : '';
                $rows .= \sprintf(
                    '<tr><td><span class="m m-%s">%s</span></td><td><code>%s</code></td><td>%s</td><td class="op">%s %s</td></tr>',
                    strtolower($m),
                    $m,
                    htmlspecialchars((string) $path, ENT_QUOTES),
                    $summary,
                    $opId,
                    $secured,
                );
            }
        }

        /** @var array<string, mixed> $components */
        $components = \is_array($doc['components'] ?? null) ? $doc['components'] : [];
        $schemaNames = array_keys(\is_array($components['schemas'] ?? null) ? $components['schemas'] : []);
        sort($schemaNames);
        $schemaList = implode(', ', array_map(static fn (string $n): string => htmlspecialchars($n, ENT_QUOTES), $schemaNames));

        return <<<HTML
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>{$title} — API</title>
            <style>
              :root{--bg:#0b1220;--card:#111c33;--line:#1e2b47;--fg:#e6edf7;--muted:#8aa0c0;--accent:#38bdf8}
              *{box-sizing:border-box}
              body{margin:0;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--fg)}
              header{padding:2rem;border-bottom:1px solid var(--line)}
              h1{margin:0 0 .25rem;font-size:1.5rem}
              .sub{color:var(--muted)}
              main{padding:2rem;max-width:1100px;margin:0 auto}
              table{width:100%;border-collapse:collapse;background:var(--card);border-radius:.75rem;overflow:hidden}
              th,td{text-align:left;padding:.75rem 1rem;border-bottom:1px solid var(--line);font-size:.9rem}
              th{color:var(--muted);font-weight:600;text-transform:uppercase;font-size:.7rem;letter-spacing:.05em}
              code{color:var(--accent)}
              .m{display:inline-block;padding:.15rem .5rem;border-radius:.35rem;font-size:.7rem;font-weight:700}
              .m-get{background:#0e4429;color:#7ee2a8}.m-post{background:#1c3a6e;color:#9cc4ff}
              .m-put{background:#5a3d0e;color:#ffd479}.m-delete{background:#5a1a1a;color:#ff9c9c}
              .op{color:var(--muted)}
              .links{margin-top:1.5rem;color:var(--muted)}
              a{color:var(--accent);text-decoration:none}
            </style></head>
            <body>
              <header><h1>{$title} <span class="sub">v{$version}</span></h1>
              <div class="sub">{$description}</div></header>
              <main>
                <table><thead><tr><th>Method</th><th>Path</th><th>Summary</th><th>Operation</th></tr></thead>
                <tbody>{$rows}</tbody></table>
                <p class="links">Components: {$schemaList}</p>
                <p class="links">Raw contract: <a href="/api/openapi.json">/api/openapi.json</a></p>
              </main>
            </body></html>
            HTML;
    }
}
