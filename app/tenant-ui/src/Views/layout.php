<?php
/**
 * App shell layout.
 *
 * @var View $this
 * @var string $content
 * @var string $title
 * @var string $theme
 * @var string $mode
 * @var array $tenant
 * @var array $flash
 * @var array $navGroups
 */
use NinjaEmp\TenantUi\Support\View;

$pageTitle = isset($title) ? $title . ' · ' . $tenant['name'] : $tenant['name'];
?>
<!doctype html>
<html lang="en" data-theme="<?= View::e($theme) ?>" data-mode="<?= View::e($mode) ?>">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title><?= View::e($pageTitle) ?></title>
  <link rel="preconnect" href="https://rsms.me/">
  <link rel="stylesheet" href="https://rsms.me/inter/inter.css">
  <link rel="stylesheet" href="/assets/css/theme.css">
  <link rel="stylesheet" href="/assets/css/app.css">
  <script>
    // Apply persisted theme/mode before paint to avoid a flash.
    (function () {
      try {
        var t = localStorage.getItem('nem-theme');
        var m = localStorage.getItem('nem-mode');
        var el = document.documentElement;
        if (t) el.setAttribute('data-theme', t);
        if (m) el.setAttribute('data-mode', m);
      } catch (e) {}
    })();
  </script>
</head>
<body>
  <?= $this->partial('partials/icons') ?>

  <div class="app" id="app" data-collapsed="false" data-mobile-open="false">
    <?= $this->partial('partials/sidebar', ['navGroups' => $navGroups, 'currentPath' => $currentPath, 'tenant' => $tenant]) ?>

    <div class="main">
      <?= $this->partial('partials/topbar', [
        'user' => $user, 'roleLabel' => $roleLabel, 'theme' => $theme, 'mode' => $mode,
        'themes' => $themes, 'modes' => $modes,
      ]) ?>

      <main class="content" id="content">
        <?php if (!empty($flash)): ?>
          <div class="grid" style="gap:var(--space-3); margin-bottom:var(--space-5)">
            <?php foreach ($flash as $msg): ?>
              <div class="alert alert-<?= View::e($msg['type']) ?>" role="status">
                <svg style="width:18px;height:18px;flex-shrink:0" aria-hidden="true"><use href="#i-check"></use></svg>
                <span><?= View::e($msg['message']) ?></span>
              </div>
            <?php endforeach; ?>
          </div>
        <?php endif; ?>

        <?= $content ?>
      </main>
    </div>

    <div class="sidebar-scrim" data-mobile-toggle></div>
  </div>

  <script src="/assets/js/app.js" defer></script>
  <?php if (!empty($pageScripts)): ?>
    <?php foreach ($pageScripts as $script): ?>
      <script src="<?= View::e($script) ?>" defer></script>
    <?php endforeach; ?>
  <?php endif; ?>
</body>
</html>
