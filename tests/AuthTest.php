<?php

declare(strict_types=1);

use NinjaEMP\Auth\Csrf;
use NinjaEMP\Auth\PasswordHasher;
use NinjaEMP\Auth\Role;
use NinjaEMP\Auth\SessionAuth;
use NinjaEMP\Auth\User;
use NinjaEMP\Tests\TestHarness;

return static function (TestHarness $t): void {
    $t->suite('Auth');

    // Role matrix.
    $t->assertTrue(Role::of(Role::OWNER)->can('settings.manage'), 'owner can manage settings');
    $t->assertFalse(Role::of(Role::CASHIER)->can('settings.manage'), 'cashier cannot manage settings');
    $t->assertTrue(Role::of(Role::CASHIER)->can('pos.use'), 'cashier can use POS');
    $t->assertFalse(Role::of(Role::ACCOUNTANT)->can('pos.use'), 'accountant cannot use POS');
    $t->assertTrue(Role::of(Role::ACCOUNTANT)->can('accounting.view'), 'accountant can view accounting');
    $t->assertThrows(InvalidArgumentException::class, fn () => Role::of('wizard'), 'unknown role rejected');
    $t->assertSame('Owner', Role::of(Role::OWNER)->label(), 'role label');

    // User.
    $user = new User('u-1', 'Dana Whitfield', Role::of(Role::OWNER), 'tenant-1');
    $t->assertSame('DW', $user->initials(), 'initials from name');
    $t->assertTrue($user->can('pos.use'), 'user inherits role permissions');

    // Password hashing.
    $hasher = new PasswordHasher();
    $hash = $hasher->hash('correct horse battery staple');
    $t->assertTrue($hash !== 'correct horse battery staple', 'hash is not plaintext');
    $t->assertTrue($hasher->verify('correct horse battery staple', $hash), 'verify correct password');
    $t->assertFalse($hasher->verify('wrong', $hash), 'reject wrong password');

    // CSRF.
    $_SESSION = [];
    $csrf = new Csrf();
    $token = $csrf->token();
    $t->assertSame(64, strlen($token), 'token is 32 bytes hex');
    $t->assertSame($token, $csrf->token(), 'token is stable within a session');
    $t->assertTrue($csrf->validate($token), 'valid token accepted');
    $t->assertFalse($csrf->validate('nope'), 'invalid token rejected');
    $t->assertFalse($csrf->validate(null), 'null token rejected');
    $csrf->rotate();
    $t->assertFalse($csrf->validate($token), 'rotated token invalidates the old one');

    // Session auth.
    $_SESSION = [];
    $auth = new SessionAuth();
    $t->assertFalse($auth->check(), 'not authenticated initially');
    $t->assertSame(null, $auth->user(), 'no user initially');

    $auth->login($user);
    $t->assertTrue($auth->check(), 'authenticated after login');
    $t->assertSame('u-1', $auth->user()?->id, 'user rehydrated');
    $t->assertSame('owner', $auth->user()?->role->code(), 'role rehydrated');
    $t->assertTrue($auth->can('settings.manage'), 'permission check via session');

    $auth->logout();
    $t->assertFalse($auth->check(), 'logged out');
    $t->assertSame(null, $auth->user(), 'no user after logout');
};
