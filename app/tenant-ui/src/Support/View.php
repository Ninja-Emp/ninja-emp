<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Support;

use RuntimeException;
use NinjaEMP\Db\Sql\Value;

/**
 * Tiny, dependency-free template renderer.
 *
 * Renders a view file inside a layout, with an optional set of partials.
 * All dynamic output MUST go through self::e() to prevent XSS.
 */
final class View
{
    private string $viewsPath;
    private string $layout = 'layout';

    /** @var array<string,mixed> */
    private array $shared = [];

    public function __construct(string $viewsPath)
    {
        $this->viewsPath = rtrim($viewsPath, '/');
    }

    /** Share a value with every view (e.g. current user, theme, nav). */
    public function share(string $key, mixed $value): void
    {
        $this->shared[$key] = $value;
    }

    public function setLayout(string $layout): void
    {
        $this->layout = $layout;
    }

    /**
     * Render a view into the layout and return the HTML string.
     *
     * @param array<string,mixed> $data
     */
    public function render(string $view, array $data = []): string
    {
        $data = array_merge($this->shared, $data);
        $content = $this->capture($view, $data);

        // The layout receives the rendered content plus the same data.
        $data['content'] = $content;

        return $this->capture($this->layout, $data);
    }

    /** Render a view with no layout (used for partials and fragments). */
    public function partial(string $view, array $data = []): string
    {
        return $this->capture($view, array_merge($this->shared, $data));
    }

    /** @param array<string,mixed> $data */
    private function capture(string $view, array $data): string
    {
        $file = $this->viewsPath . '/' . $view . '.php';

        if (!is_file($file)) {
            throw new RuntimeException("View not found: {$view} ({$file})");
        }
        extract($data, EXTR_SKIP);
        ob_start();
        require $file;

        return (string) ob_get_clean();
    }

    /** Escape a value for safe HTML output. */
    public static function e(mixed $value): string
    {
        return htmlspecialchars(Value::str($value), ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
    }
}
