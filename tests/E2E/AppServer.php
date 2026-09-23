<?php

declare(strict_types=1);

namespace NinjaEMP\Tests\E2E;

use RuntimeException;

/**
 * Boots one of the application front controllers under PHP's built-in web
 * server and drives it over real HTTP.
 *
 * This is the "grandma can use it" acceptance layer (HANDOFF.md §4 step 8): the
 * request enters through the same `public/router.php` → `public/index.php` path
 * a browser would take, exercises the real router/middleware/views, and returns
 * the response. Nothing is stubbed.
 *
 * A free port is chosen per instance so suites can run side by side; readiness
 * is polled so tests never race the server's startup.
 */
final class AppServer
{
    /** @var resource|null */
    private $process = null;

    private int $port = 0;

    private string $logFile = '';

    public function __construct(
        private readonly string $docroot,
        private readonly string $router,
    ) {
    }

    public function start(): void
    {
        $this->port = self::findFreePort();
        $this->logFile = (string) tempnam(sys_get_temp_dir(), 'ninja_e2e_');

        $command = [
            PHP_BINARY,
            '-d', 'display_errors=0',
            '-S', '127.0.0.1:' . $this->port,
            '-t', $this->docroot,
            $this->router,
        ];

        $descriptors = [
            0 => ['file', '/dev/null', 'r'],
            1 => ['file', $this->logFile, 'a'],
            2 => ['file', $this->logFile, 'a'],
        ];

        $process = proc_open($command, $descriptors, $pipes, $this->docroot);

        if (!\is_resource($process)) {
            throw new RuntimeException('Failed to start the PHP built-in server.');
        }

        $this->process = $process;
        $this->waitUntilReady();
    }

    public function stop(): void
    {
        if (\is_resource($this->process)) {
            proc_terminate($this->process);
            proc_close($this->process);
            $this->process = null;
        }

        if ($this->logFile !== '' && is_file($this->logFile)) {
            @unlink($this->logFile);
        }
    }

    public function baseUrl(): string
    {
        return 'http://127.0.0.1:' . $this->port;
    }

    /**
     * @param array<string,string> $headers
     */
    public function get(string $path, array $headers = []): HttpResponse
    {
        return $this->request('GET', $path, [], $headers);
    }

    /**
     * @param array<string,string> $data
     * @param array<string,string> $headers
     */
    public function post(string $path, array $data = [], array $headers = []): HttpResponse
    {
        return $this->request('POST', $path, $data, $headers);
    }

    /**
     * @param array<string,string> $data
     * @param array<string,string> $headers
     */
    private function request(string $method, string $path, array $data, array $headers): HttpResponse
    {
        $headerLines = '';

        foreach ($headers as $name => $value) {
            $headerLines .= $name . ': ' . $value . "\r\n";
        }

        $options = [
            'http' => [
                'method' => $method,
                'ignore_errors' => true,
                'timeout' => 15,
                'follow_location' => 0,
                'header' => $headerLines,
            ],
        ];

        if ($method === 'POST') {
            $options['http']['header'] = $headerLines . "Content-Type: application/x-www-form-urlencoded\r\n";
            $options['http']['content'] = http_build_query($data);
        }

        $context = stream_context_create($options);
        $body = @file_get_contents($this->baseUrl() . $path, false, $context);

        /** @var list<string> $responseHeaders */
        $responseHeaders = $http_response_header ?? [];

        return new HttpResponse(
            self::statusFromHeaders($responseHeaders),
            $body === false ? '' : $body,
            $responseHeaders,
        );
    }

    /**
     * @param list<string> $headers
     */
    private static function statusFromHeaders(array $headers): int
    {
        $status = 0;

        foreach ($headers as $header) {
            if (preg_match('#^HTTP/\S+\s+(\d{3})#', $header, $matches) === 1) {
                $status = (int) $matches[1];
            }
        }

        return $status;
    }

    private function waitUntilReady(): void
    {
        $deadline = microtime(true) + 10.0;

        while (microtime(true) < $deadline) {
            $socket = @fsockopen('127.0.0.1', $this->port, $errno, $errstr, 0.25);

            if (\is_resource($socket)) {
                fclose($socket);

                return;
            }

            usleep(50_000);
        }

        $log = is_file($this->logFile) ? (string) file_get_contents($this->logFile) : '';

        throw new RuntimeException(
            'The PHP built-in server did not become ready on port ' . $this->port . ".\n" . $log,
        );
    }

    private static function findFreePort(): int
    {
        $socket = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);

        if ($socket === false) {
            throw new RuntimeException('Unable to allocate a free TCP port: ' . $errstr);
        }

        $name = (string) stream_socket_get_name($socket, false);
        fclose($socket);

        $colon = strrpos($name, ':');

        if ($colon === false) {
            throw new RuntimeException('Unable to parse the allocated port from "' . $name . '".');
        }

        return (int) substr($name, $colon + 1);
    }
}
