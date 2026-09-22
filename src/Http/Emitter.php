<?php

declare(strict_types=1);

namespace NinjaEMP\Http;

use NinjaEMP\Db\Sql\Value;
use Psr\Http\Message\ResponseInterface;

/**
 * Emits a PSR-7 response to the SAPI (headers + body). Kept separate from the
 * kernel so the kernel stays testable without touching global state.
 */
final class Emitter
{
    public function emit(ResponseInterface $response): void
    {
        if (!headers_sent()) {
            $this->emitStatusLine($response);
            $this->emitHeaders($response);
        }

        $this->emitBody($response);
    }

    private function emitStatusLine(ResponseInterface $response): void
    {
        $reason = $response->getReasonPhrase();
        $line = \sprintf(
            '%s %d%s',
            Value::str($_SERVER['SERVER_PROTOCOL'] ?? 'HTTP/1.1'),
            $response->getStatusCode(),
            $reason !== '' ? ' ' . $reason : '',
        );
        header($line, true, $response->getStatusCode());
    }

    private function emitHeaders(ResponseInterface $response): void
    {
        foreach ($response->getHeaders() as $name => $values) {
            $first = true;

            foreach ($values as $value) {
                header(\sprintf('%s: %s', $name, $value), $first);
                $first = false;
            }
        }
    }

    private function emitBody(ResponseInterface $response): void
    {
        $body = $response->getBody();

        if ($body->isSeekable()) {
            $body->rewind();
        }

        echo $body->getContents();
    }
}
