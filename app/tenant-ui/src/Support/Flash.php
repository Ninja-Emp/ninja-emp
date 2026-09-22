<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Support;

/**
 * One-shot flash messages stored in the session.
 */
final class Flash
{
    public static function start(): void
    {
        if (session_status() !== PHP_SESSION_ACTIVE) {
            session_start();
        }
    }

    public static function add(string $type, string $message): void
    {
        self::start();
        $flash = self::read();
        $flash[] = ['type' => $type, 'message' => $message];
        $_SESSION['_flash'] = $flash;
    }

    /** @return list<array{type:string,message:string}> */
    public static function pull(): array
    {
        self::start();
        $flash = self::read();
        unset($_SESSION['_flash']);

        return $flash;
    }

    /** @return list<array{type:string,message:string}> */
    private static function read(): array
    {
        $raw = $_SESSION['_flash'] ?? null;

        if (!\is_array($raw)) {
            return [];
        }

        $out = [];

        foreach ($raw as $item) {
            if (\is_array($item) && \is_string($item['type'] ?? null) && \is_string($item['message'] ?? null)) {
                $out[] = ['type' => $item['type'], 'message' => $item['message']];
            }
        }

        return $out;
    }
}
