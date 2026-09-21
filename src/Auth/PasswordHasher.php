<?php

declare(strict_types=1);

namespace NinjaEMP\Auth;

/**
 * Password hashing. Uses PHP's built-in password_hash with Argon2id when
 * available, falling back to bcrypt. Never stores or compares plaintext.
 */
final class PasswordHasher
{
    private const ALGO = PASSWORD_ARGON2ID;

    public function hash(string $plaintext): string
    {
        $algo = defined('PASSWORD_ARGON2ID') ? self::ALGO : PASSWORD_BCRYPT;

        $hash = password_hash($plaintext, $algo);

        if ($hash === false) {
            throw new \RuntimeException('Password hashing failed.');
        }

        return $hash;
    }

    public function verify(string $plaintext, string $hash): bool
    {
        return password_verify($plaintext, $hash);
    }

    /** True when the stored hash should be upgraded to the current algorithm. */
    public function needsRehash(string $hash): bool
    {
        $algo = defined('PASSWORD_ARGON2ID') ? self::ALGO : PASSWORD_BCRYPT;

        return password_needs_rehash($hash, $algo);
    }
}
