<?php
/**
 * Login (mock role picker).
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\View;

?>
<div style="min-height:100vh; display:grid; place-items:center; padding:var(--space-6); background:var(--bg)">
  <div style="width:100%; max-width:420px">
    <div class="row gap-3" style="justify-content:center; margin-bottom:var(--space-6)">
      <span class="brand-mark" style="width:40px;height:40px;font-size:var(--text-lg)">N</span>
      <div>
        <div class="h2"><?= View::e($tenant['name']) ?></div>
        <div class="text-sm muted">Ninja EMP · Tenant Console</div>
      </div>
    </div>

    <div class="card">
      <div class="card-head"><div class="h3">Sign in</div></div>
      <div class="card-body grid" style="gap:var(--space-4)">
        <p class="muted text-sm">This is a demo. Choose a role to explore the role-aware console.</p>
        <div class="grid" style="gap:var(--space-2)">
          <?php foreach ($roles as $key => $label): ?>
            <a class="btn btn-block" href="?role=<?= View::e($key) ?>" style="justify-content:flex-start">
              <svg aria-hidden="true"><use href="#i-user"></use></svg>
              Continue as <?= View::e($label) ?>
            </a>
          <?php endforeach; ?>
        </div>
      </div>
      <div class="card-foot text-xs subtle">
        Production uses real authentication (sessions + party roles). This screen is a mock.
      </div>
    </div>
  </div>
</div>
