<?php
/**
 * Top bar: mobile menu, global search, theme switcher, account menu.
 *
 * @var View $this
 * @var array $user
 * @var string $roleLabel
 * @var string $theme
 * @var string $mode
 * @var array $themes
 * @var array $modes
 */
use NinjaEmp\TenantUi\Support\View;

?>
<header class="topbar">
  <button class="icon-btn mobile-only" type="button" data-mobile-toggle aria-label="Open navigation">
    <svg aria-hidden="true"><use href="#i-menu"></use></svg>
  </button>

  <form class="topbar-search" role="search" action="/inventory" method="get">
    <svg aria-hidden="true"><use href="#i-search"></use></svg>
    <input type="search" name="q" placeholder="Search items, vendors, booths…"
           aria-label="Search" autocomplete="off" data-global-search>
    <kbd>/</kbd>
  </form>

  <div class="topbar-spacer"></div>

  <div class="topbar-actions">
    <button class="icon-btn" type="button" aria-label="Notifications">
      <svg aria-hidden="true"><use href="#i-bell"></use></svg>
    </button>

    <!-- Theme switcher -->
    <div class="account" data-menu>
      <button class="icon-btn" type="button" data-menu-trigger aria-haspopup="true" aria-expanded="false" aria-label="Appearance">
        <svg aria-hidden="true"><use href="#i-palette"></use></svg>
      </button>
      <div class="menu" data-menu-panel hidden>
        <div class="menu-label">Theme</div>
        <?php foreach ($themes as $key => $meta): ?>
          <button class="menu-item" type="button" role="menuitemradio"
                  data-set-theme="<?= View::e($key) ?>"
                  aria-checked="<?= $key === $theme ? 'true' : 'false' ?>">
            <span class="swatch" style="background: <?= View::e($meta['swatch']) ?>"></span>
            <?= View::e($meta['label']) ?>
            <svg style="margin-left:auto" aria-hidden="true"><use href="#i-check"></use></svg>
          </button>
        <?php endforeach; ?>
        <div class="menu-sep"></div>
        <div class="menu-label">Mode</div>
        <?php foreach ($modes as $m): ?>
          <button class="menu-item" type="button" role="menuitemradio"
                  data-set-mode="<?= View::e($m) ?>"
                  aria-checked="<?= $m === $mode ? 'true' : 'false' ?>">
            <svg aria-hidden="true"><use href="#<?= $m === 'dark' ? 'i-moon' : 'i-sun' ?>"></use></svg>
            <?= View::e(ucfirst($m)) ?>
            <svg style="margin-left:auto" aria-hidden="true"><use href="#i-check"></use></svg>
          </button>
        <?php endforeach; ?>
      </div>
    </div>

    <!-- Account -->
    <div class="account" data-menu>
      <button class="account-btn" type="button" data-menu-trigger aria-haspopup="true" aria-expanded="false">
        <span class="avatar" aria-hidden="true"><?= View::e($user['initials'] ?? 'U') ?></span>
        <span class="account-meta">
          <span class="name"><?= View::e($user['name'] ?? 'User') ?></span>
          <span class="role"><?= View::e($roleLabel) ?></span>
        </span>
        <svg style="width:14px;height:14px;color:var(--text-subtle)" aria-hidden="true"><use href="#i-chevron-down"></use></svg>
      </button>
      <div class="menu" data-menu-panel hidden>
        <div class="menu-label">Switch role (demo)</div>
        <?php foreach (NinjaEmp\TenantUi\Support\Auth::roles() as $key => $label): ?>
          <a class="menu-item" href="?role=<?= View::e($key) ?>"
             aria-checked="<?= $key === ($user['role'] ?? '') ? 'true' : 'false' ?>">
            <svg aria-hidden="true"><use href="#i-user"></use></svg>
            <?= View::e($label) ?>
            <svg style="margin-left:auto" aria-hidden="true"><use href="#i-check"></use></svg>
          </a>
        <?php endforeach; ?>
        <div class="menu-sep"></div>
        <a class="menu-item" href="/settings">
          <svg aria-hidden="true"><use href="#i-settings"></use></svg> Settings
        </a>
        <a class="menu-item" href="/logout">
          <svg aria-hidden="true"><use href="#i-logout"></use></svg> Sign out
        </a>
      </div>
    </div>
  </div>
</header>
