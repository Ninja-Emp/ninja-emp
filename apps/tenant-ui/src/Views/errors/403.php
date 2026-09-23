<?php
/**
 * @var View $this
 * @var string $permission
 */
use NinjaEmp\TenantUi\Support\View;

?>
<div class="empty" style="padding-top:var(--space-12)">
  <svg aria-hidden="true"><use href="#i-lock"></use></svg>
  <h1 class="h2">Access denied</h1>
  <p class="muted mt-2">
    Your role doesn’t have permission to view this area
    (<span class="mono"><?= View::e($permission) ?></span>).
  </p>
  <p class="muted mt-2">Switch roles from the account menu, or ask an owner to grant access.</p>
  <a class="btn btn-primary mt-6" href="/">Back to dashboard</a>
</div>
