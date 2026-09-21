<?php
/**
 * Bare layout (no shell) — used for the login screen.
 *
 * @var \NinjaEmp\TenantUi\Support\View $this
 * @var string $content
 * @var string $title
 * @var string $theme
 * @var string $mode
 * @var array $tenant
 */
use NinjaEmp\TenantUi\Support\View;
?>
<!doctype html>
<html lang="en" data-theme="<?= View::e($theme) ?>" data-mode="<?= View::e($mode) ?>">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title><?= View::e($title) ?> · <?= View::e($tenant['name']) ?></title>
  <link rel="stylesheet" href="https://rsms.me/inter/inter.css">
  <link rel="stylesheet" href="/assets/css/theme.css">
  <link rel="stylesheet" href="/assets/css/app.css">
</head>
<body>
  <?= $this->partial('partials/icons') ?>
  <?= $content ?>
</body>
</html>
