<?php

declare(strict_types=1);

namespace NinjaEMP\Http\Message;

use Psr\Http\Message\ResponseInterface;

/**
 * A convenience response that serialises a payload as JSON.
 */
final class JsonResponse
{
    /**
     * @param array<string, mixed>|list<mixed> $payload
     * @param array<string, string> $headers
     */
    public static function of(array $payload, int $status = 200, array $headers = []): ResponseInterface
    {
        $body = json_encode($payload, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
        $headers['Content-Type'] = 'application/json; charset=utf-8';

        return new Response($status, $body === false ? '{}' : $body, $headers);
    }

    /**
     * @param array<string, mixed> $errors
     */
    public static function error(string $message, int $status = 400, array $errors = []): ResponseInterface
    {
        $payload = ['error' => ['status' => $status, 'message' => $message]];

        if ($errors !== []) {
            $payload['error']['details'] = $errors;
        }

        return self::of($payload, $status);
    }
}
