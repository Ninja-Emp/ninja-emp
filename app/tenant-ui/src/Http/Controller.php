<?php

declare(strict_types=1);

namespace NinjaEmp\TenantUi\Http;

use NinjaEmp\TenantUi\Data\MockRepository;
use NinjaEmp\TenantUi\Support\Auth;
use NinjaEmp\TenantUi\Support\Flash;
use NinjaEmp\TenantUi\Support\View;

/**
 * Base controller.
 *
 * Holds the shared services and provides small helpers for rendering views,
 * redirecting, gating routes by permission, and reading request input.
 * Controllers stay thin: gather data, hand to a view.
 */
abstract class Controller
{
    public function __construct(
        protected MockRepository $repo,
        protected Auth $auth,
        protected View $view,
    ) {
    }

    /** Render a view into the app shell. */
    protected function render(string $view, array $data = []): void
    {
        echo $this->view->render($view, $data);
    }

    /** Render a view with no shell (used for full-page islands / fragments). */
    protected function renderBare(string $view, array $data = []): void
    {
        echo $this->view->partial($view, $data);
    }

    /** Redirect to a path and stop. */
    protected function redirect(string $path): never
    {
        header('Location: ' . $path, true, 302);
        exit;
    }

    /**
     * Gate a route by permission. If the current role lacks it, show a
     * friendly 403 page (rather than a hard crash) and stop.
     */
    protected function require(string $permission): void
    {
        if ($this->auth->can($permission)) {
            return;
        }
        http_response_code(403);
        $this->render('errors/403', [
            'title'      => 'Access denied',
            'permission' => $permission,
        ]);
        exit;
    }

    /** Read a trimmed string from POST. */
    protected function input(string $key, string $default = ''): string
    {
        $value = $_POST[$key] ?? $default;

        return \is_string($value) ? trim($value) : $default;
    }

    /** Read a trimmed string from GET. */
    protected function query(string $key, string $default = ''): string
    {
        $value = $_GET[$key] ?? $default;

        return \is_string($value) ? trim($value) : $default;
    }

    /** Add a flash message for the next request. */
    protected function flash(string $type, string $message): void
    {
        Flash::add($type, $message);
    }
}
