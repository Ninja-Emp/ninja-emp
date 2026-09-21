<?php
/**
 * Vendors list.
 * @var \NinjaEmp\TenantUi\Support\View $this
 */
use NinjaEmp\TenantUi\Support\View;
use NinjaEmp\TenantUi\Support\Money;

$cur = $tenant['currency'];
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Vendors</h1>
    <p class="muted">Consignors and vendors, their booths, and what we owe them.</p>
  </div>
  <div class="row gap-2">
    <span class="badge badge-accent">Total payable <?= View::e(Money::format($totalPayable, $cur)) ?></span>
    <a class="btn btn-primary" href="/vendors/new"><svg aria-hidden="true"><use href="#i-plus"></use></svg> New vendor</a>
  </div>
</div>

<div class="card">
  <div class="table-wrap">
    <table class="table">
      <thead>
        <tr><th>Vendor</th><th>Contact</th><th>Type</th><th>Booth(s)</th><th class="num">Commission</th><th class="num">Balance owed</th><th>Status</th><th></th></tr>
      </thead>
      <tbody>
        <?php foreach ($vendors as $v): ?>
          <tr>
            <td>
              <a class="strong" href="/vendors/<?= View::e($v['id']) ?>"><?= View::e($v['name']) ?></a>
              <div class="text-xs subtle">Since <?= View::e($v['since']) ?></div>
            </td>
            <td>
              <div><?= View::e($v['contact']) ?></div>
              <div class="text-xs subtle"><?= View::e($v['email']) ?></div>
            </td>
            <td><span class="badge"><?= View::e(ucfirst($v['type'])) ?></span></td>
            <td class="mono text-sm"><?= View::e(implode(', ', $booths[$v['id']] ?? ['—'])) ?></td>
            <td class="num tnum"><?= View::e(rtrim(rtrim($v['commission'], '0'), '.')) ?>%</td>
            <td class="num strong tnum"><?= View::e(Money::format($v['balance'], $cur)) ?></td>
            <td>
              <span class="badge <?= $v['status'] === 'active' ? 'badge-success' : 'badge-warning' ?> badge-dot"><?= View::e(ucfirst($v['status'])) ?></span>
            </td>
            <td class="num">
              <a class="btn btn-sm btn-ghost" href="/vendors/<?= View::e($v['id']) ?>/edit"><svg aria-hidden="true"><use href="#i-edit"></use></svg> Edit</a>
            </td>
          </tr>
        <?php endforeach; ?>
      </tbody>
    </table>
  </div>
</div>
