<?php

declare(strict_types=1);

namespace NinjaEMP\Http;

use NinjaEMP\Http\Exception\HttpException;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Throwable;

/**
 * Renders an uncaught throwable into a response. Content-negotiates between a
 * JSON error envelope (for API clients) and a plain HTML page (for browsers).
 */
final class ErrorRenderer
{
    public function __construct(private readonly bool $debug = false)
    {
    }

    public function render(ServerRequestInterface $request, Throwable $error): ResponseInterface
    {
        $status = $error instanceof HttpException ? $error->statusCode() : 500;

        if ($this->wantsJson($request)) {
            return $this->json($status, $error);
        }

        return $this->html($status, $error);
    }

    private function wantsJson(ServerRequestInterface $request): bool
    {
        $accept = $request->getHeaderLine('Accept');
        $path = $request->getUri()->getPath();

        return str_contains($accept, 'application/json')
            || str_starts_with($path, '/api/');
    }

    private function json(int $status, Throwable $error): ResponseInterface
    {
        $payload = [
            'error' => [
                'status' => $status,
                'message' => $error->getMessage(),
            ],
        ];

        if ($this->debug && !$error instanceof HttpException) {
            $payload['error']['type'] = $error::class;
            $payload['error']['trace'] = explode("\n", $error->getTraceAsString());
        }

        $body = json_encode($payload, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);

        return new Message\Response(
            $status,
            \is_string($body) ? $body : '{}',
            ['Content-Type' => 'application/json'],
        );
    }

    private function html(int $status, Throwable $error): ResponseInterface
    {
        $title = htmlspecialchars($this->title($status), ENT_QUOTES);
        $message = htmlspecialchars($error->getMessage(), ENT_QUOTES);
        $detail = '';

        if ($this->debug && !$error instanceof HttpException) {
            $detail = '<pre class="trace">' . htmlspecialchars($error->getTraceAsString(), ENT_QUOTES) . '</pre>';
        }

        $body = <<<HTML
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>{$status} — {$title}</title>
            <style>
              body{font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#0f172a;color:#e2e8f0;
                   display:flex;min-height:100vh;align-items:center;justify-content:center;margin:0}
              .card{max-width:560px;padding:2.5rem;text-align:center}
              .code{font-size:4rem;font-weight:700;color:#38bdf8;margin:0}
              h1{font-size:1.25rem;margin:.5rem 0 1rem}
              p{color:#94a3b8;line-height:1.6}
              a{color:#38bdf8;text-decoration:none}
              .trace{text-align:left;background:#1e293b;padding:1rem;border-radius:.5rem;overflow:auto;font-size:.75rem}
            </style></head>
            <body><div class="card">
              <p class="code">{$status}</p>
              <h1>{$title}</h1>
              <p>{$message}</p>
              {$detail}
              <p><a href="/">Return to dashboard</a></p>
            </div></body></html>
            HTML;

        return new Message\Response($status, $body, ['Content-Type' => 'text/html; charset=utf-8']);
    }

    private function title(int $status): string
    {
        return match ($status) {
            400 => 'Bad request',
            401 => 'Authentication required',
            403 => 'Access denied',
            404 => 'Not found',
            405 => 'Method not allowed',
            409 => 'Conflict',
            422 => 'Unprocessable entity',
            429 => 'Too many requests',
            default => 'Something went wrong',
        };
    }
}
