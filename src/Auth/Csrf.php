<?php

declare(strict_types=1);

namespace NinjaEMP\Auth;

/**
 * CSRF token generation and constant-time validation.
 *
 * The token is a random 32-byte value stored in the session and echoed into forms
 * as a hidden field. Validation uses hash_equals to avoid timing leaks.
 */
final class Csrf
{
    public const FIELD = '_csrf';

    public function __construct(private readonly string $sessionKey = 'nem_csrf')
    {
    }

    /** Return the current token, generating one on first use. */
    public function token(): string
    {
        if (!isset($_SESSION[$this->sessionKey]) || !is_string($_SESSION[$this->sessionKey])) {
            $_SESSION[$this->sessionKey] = bin2hex(random_bytes(32));
        }

        return $_SESSION[$this->sessionKey];
    }

    public function validate(?string $candidate): bool
    {
        $expected = $_SESSION[$this->sessionKey] ?? null;

        if (!is_string($expected) || $expected === '' || $candidate === null || $candidate === '') {
            return false;
        }

        return hash_equals($expected, $candidate);
    }

    /** Rotate the token (call after login/logout). */
    public function rotate(): void
    {
        $_SESSION[$this->sessionKey] = bin2hex(random_bytes(32));
    }
}
