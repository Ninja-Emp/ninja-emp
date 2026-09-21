<?php
declare(strict_types=1);

namespace NinjaEmp\TenantUi\Support;

/**
 * Theme registry.
 *
 * A "theme" is a palette; a "mode" is light/dark. Both are expressed as data
 * attributes on <html> and resolved entirely by CSS custom properties, so
 * adding a theme is a CSS-only change plus one entry here.
 */
final class Theme
{
    /** @var array<string,array{label:string,swatch:string}> */
    private const THEMES = [
        'neutral'   => ['label' => 'Neutral',   'swatch' => '#4f46e5'],
        'dark-blue' => ['label' => 'Dark Blue', 'swatch' => '#1e3a8a'],
    ];

    private const MODES = ['light', 'dark'];

    public static function themes(): array
    {
        return self::THEMES;
    }

    public static function modes(): array
    {
        return self::MODES;
    }

    public static function isValidTheme(string $theme): bool
    {
        return isset(self::THEMES[$theme]);
    }

    public static function isValidMode(string $mode): bool
    {
        return in_array($mode, self::MODES, true);
    }

    public static function defaultTheme(): string
    {
        return 'neutral';
    }

    public static function defaultMode(): string
    {
        return 'light';
    }
}
