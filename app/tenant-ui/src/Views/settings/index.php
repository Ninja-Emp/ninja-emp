<?php
/**
 * Settings.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\View;

$permLabels = [
    'dashboard.view' => 'Dashboard', 'pos.use' => 'Point of Sale', 'booths.manage' => 'Booths',
    'vendors.manage' => 'Vendors', 'inventory.manage' => 'Inventory', 'reports.view' => 'Reports',
    'settings.manage' => 'Settings', 'accounting.view' => 'Accounting',
];
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Settings</h1>
    <p class="muted">Appearance, roles, and tenant configuration.</p>
  </div>
</div>

<div class="grid cols-2">
  <div class="card">
    <div class="card-head"><div class="h3">Appearance</div></div>
    <form method="post" action="/settings">
      <div class="card-body grid" style="gap:var(--space-5)">
        <div class="field">
          <label>Theme</label>
          <div class="grid cols-2" style="gap:var(--space-3)">
            <?php foreach ($themes as $key => $meta): ?>
              <label class="theme-option" style="border-color: <?= $key === $theme ? 'var(--accent)' : 'var(--border)' ?>">
                <input type="radio" name="theme" value="<?= View::e($key) ?>" <?= $key === $theme ? 'checked' : '' ?>>
                <span class="swatch" style="width:22px;height:22px;background:<?= View::e($meta['swatch']) ?>"></span>
                <span class="strong"><?= View::e($meta['label']) ?></span>
              </label>
            <?php endforeach; ?>
          </div>
        </div>
        <div class="field">
          <label>Mode</label>
          <div class="segmented">
            <?php foreach ($modes as $m): ?>
              <label style="cursor:pointer">
                <input type="radio" name="mode" value="<?= View::e($m) ?>" <?= $m === $mode ? 'checked' : '' ?> class="sr-only">
                <span class="seg-btn" style="display:inline-block;padding:5px 12px;border-radius:6px;<?= $m === $mode ? 'background:var(--surface);box-shadow:var(--shadow-xs)' : 'color:var(--text-muted)' ?>"><?= View::e(ucfirst($m)) ?></span>
              </label>
            <?php endforeach; ?>
          </div>
        </div>
      </div>
      <div class="card-foot row between">
        <span class="text-sm muted">Theme applies instantly and is remembered.</span>
        <button class="btn btn-primary" type="submit"><svg aria-hidden="true"><use href="#i-check"></use></svg> Save</button>
      </div>
    </form>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Tenant</div></div>
    <form method="post" action="/settings">
      <div class="card-body grid" style="gap:var(--space-4)">
        <div class="field">
          <label for="name">Business name</label>
          <input class="input" id="name" name="name" value="<?= View::e($tenant['name']) ?>" required>
        </div>
        <div class="grid cols-2" style="gap:var(--space-3)">
          <div class="field">
            <label for="currency">Currency</label>
            <select class="select" id="currency" name="currency">
              <?php foreach (['USD', 'EUR', 'GBP', 'CAD', 'AUD'] as $c): ?>
                <option value="<?= View::e($c) ?>" <?= $tenant['currency'] === $c ? 'selected' : '' ?>><?= View::e($c) ?></option>
              <?php endforeach; ?>
            </select>
          </div>
          <div class="field">
            <label for="timezone">Timezone</label>
            <select class="select" id="timezone" name="timezone">
              <?php foreach (['America/New_York', 'America/Chicago', 'America/Denver', 'America/Los_Angeles', 'Europe/London', 'Europe/Berlin', 'UTC'] as $tz): ?>
                <option value="<?= View::e($tz) ?>" <?= $tenant['timezone'] === $tz ? 'selected' : '' ?>><?= View::e($tz) ?></option>
              <?php endforeach; ?>
            </select>
          </div>
        </div>
        <div class="row between">
          <span class="muted">Slug</span><span class="mono"><?= View::e($tenant['slug']) ?></span>
        </div>
      </div>
      <div class="card-foot row between">
        <span class="text-sm muted">Business name, currency, and timezone.</span>
        <button class="btn btn-primary" type="submit"><svg aria-hidden="true"><use href="#i-check"></use></svg> Save</button>
      </div>
    </form>
  </div>
</div>

<div class="card mt-6">
  <div class="card-head">
    <div class="h3">Roles &amp; permissions</div>
    <span class="text-sm muted">Role-aware navigation and route gating</span>
  </div>
  <div class="table-wrap">
    <table class="table">
      <thead>
        <tr>
          <th>Permission</th>
          <?php foreach ($roles as $key => $label): ?>
            <th style="text-align:center"><?= View::e($label) ?></th>
          <?php endforeach; ?>
        </tr>
      </thead>
      <tbody>
        <?php foreach ($permissions['permissions'] as $perm): ?>
          <tr>
            <td class="strong"><?= View::e($permLabels[$perm] ?? $perm) ?></td>
            <?php foreach (array_keys($roles) as $role): ?>
              <td style="text-align:center">
                <?php if ($permissions['roles'][$role][$perm]): ?>
                  <svg style="width:16px;height:16px;color:var(--success);margin:0 auto" aria-hidden="true"><use href="#i-check"></use></svg>
                <?php else: ?>
                  <span class="subtle">—</span>
                <?php endif; ?>
              </td>
            <?php endforeach; ?>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </div>
</div>

<script>
  // Keep localStorage in sync with the settings form so the pre-paint theme
  // script in the layout (which reads localStorage) agrees with the session.
  (function () {
    var form = document.querySelector('form[action="/settings"]');
    if (!form) return;

    // Reflect the actually-applied theme/mode (localStorage wins at paint time).
    try {
      var lt = localStorage.getItem('nem-theme');
      var lm = localStorage.getItem('nem-mode');
      if (lt) { var rt = form.querySelector('input[name="theme"][value="' + lt + '"]'); if (rt) rt.checked = true; }
      if (lm) { var rm = form.querySelector('input[name="mode"][value="' + lm + '"]'); if (rm) rm.checked = true; }
    } catch (e) {}

    form.addEventListener('submit', function () {
      try {
        var t = form.querySelector('input[name="theme"]:checked');
        var m = form.querySelector('input[name="mode"]:checked');
        if (t) localStorage.setItem('nem-theme', t.value);
        if (m) localStorage.setItem('nem-mode', m.value);
      } catch (e) {}
    });
  })();
</script>
