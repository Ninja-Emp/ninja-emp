<?php
/**
 * Booths list.
 * @var \NinjaEmp\TenantUi\Support\View $this
 */
use NinjaEmp\TenantUi\Support\View;
use NinjaEmp\TenantUi\Support\Money;

$cur = $tenant['currency'];
$statusBadge = [
    'leased' => 'badge-success', 'available' => 'badge-info', 'reserved' => 'badge-accent',
    'maintenance' => 'badge-warning', 'inactive' => '',
];
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Booths</h1>
    <p class="muted">Manage spaces, leases, and occupancy across the floor.</p>
  </div>
  <div class="row gap-2">
    <a class="btn" href="/booths/map"><svg aria-hidden="true"><use href="#i-map"></use></svg> Map view</a>
    <a class="btn btn-primary" href="/booths/new"><svg aria-hidden="true"><use href="#i-plus"></use></svg> New booth</a>
  </div>
</div>

<div class="grid cols-4">
  <?php foreach (['leased' => 'Leased', 'available' => 'Available', 'reserved' => 'Reserved', 'maintenance' => 'Maintenance'] as $k => $label): ?>
    <div class="stat">
      <div class="stat-label"><?= View::e($label) ?></div>
      <div class="stat-value"><?= View::e((string) ($statusCounts[$k] ?? 0)) ?></div>
    </div>
  <?php endforeach; ?>
</div>

<div class="card mt-6">
  <div class="table-wrap">
    <table class="table">
      <thead>
        <tr>
          <th>Booth</th><th>Type</th><th>Size</th><th>Status</th><th>Vendor</th>
          <th class="num">Monthly rent</th><th></th>
        </tr>
      </thead>
      <tbody>
        <?php foreach ($spaces as $s): ?>
          <tr>
            <td><a class="strong mono" href="/booths/<?= View::e($s['id']) ?>"><?= View::e($s['code']) ?></a></td>
            <td class="muted"><?= View::e(ucfirst($s['type'])) ?></td>
            <td class="muted tnum"><?= View::e((string) $s['sqft']) ?> sq ft</td>
            <td><span class="badge <?= View::e($statusBadge[$s['status']] ?? '') ?> badge-dot"><?= View::e(ucfirst($s['status'])) ?></span></td>
            <td>
              <?php if ($s['vendor_id'] && isset($vendorNames[$s['vendor_id']])): ?>
                <a href="/vendors/<?= View::e($s['vendor_id']) ?>"><?= View::e($vendorNames[$s['vendor_id']]) ?></a>
              <?php else: ?>
                <span class="subtle">—</span>
              <?php endif; ?>
            </td>
            <td class="num tnum"><?= View::e(Money::format($s['rent'], $cur)) ?></td>
            <td class="num"><a class="btn btn-sm btn-ghost" href="/booths/<?= View::e($s['id']) ?>"><svg aria-hidden="true"><use href="#i-edit"></use></svg></a></td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </div>
</div>
