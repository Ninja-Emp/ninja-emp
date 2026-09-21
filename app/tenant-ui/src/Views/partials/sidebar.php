<?php
/**
 * Sidebar navigation. Role-aware (items filtered by permission).
 *
 * @var \NinjaEmp\TenantUi\Support\View $this
 * @var array $navGroups
 * @var string $currentPath
 * @var array $tenant
 */
use NinjaEmp\TenantUi\Support\View;
?>
<aside class="sidebar" id="sidebar" aria-label="Primary">
  <div class="sidebar-brand">
    <span class="brand-mark" aria-hidden="true">N</span>
    <span class="brand-text">
      <span class="name"><?= View::e($tenant['name']) ?></span>
      <span class="sub">Ninja EMP · Tenant</span>
    </span>
  </div>

  <nav class="sidebar-nav">
    <?php foreach ($navGroups as $group): ?>
      <div class="nav-group-label"><?= View::e($group['label']) ?></div>
      <?php foreach ($group['items'] as $item): ?>
        <?php
          $isActive = $item['path'] === '/'
              ? $currentPath === '/'
              : str_starts_with($currentPath, $item['path']);
        ?>
        <a class="nav-item"
           href="<?= View::e($item['path']) ?>"
           <?= $isActive ? 'aria-current="page"' : '' ?>
           title="<?= View::e($item['label']) ?>">
          <svg aria-hidden="true"><use href="#<?= View::e($item['icon']) ?>"></use></svg>
          <span class="nav-label"><?= View::e($item['label']) ?></span>
          <?php if (!empty($item['badge'])): ?>
            <span class="nav-badge"><?= View::e($item['badge']) ?></span>
          <?php endif; ?>
        </a>
      <?php endforeach; ?>
    <?php endforeach; ?>
  </nav>

  <div class="sidebar-foot">
    <button class="collapse-btn" type="button" data-collapse-toggle aria-label="Collapse sidebar">
      <svg aria-hidden="true"><use href="#i-chevron"></use></svg>
      <span>Collapse</span>
    </button>
  </div>
</aside>
