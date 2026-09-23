<?php
/**
 * Inventory item detail.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\Money;
use NinjaEmp\TenantUi\Support\View;

$cur = $tenant['currency'];
$low = $item['on_hand'] <= $item['reorder'];
$margin = bccomp($item['price'], '0', 4) > 0
    ? (float) bcdiv(bcmul(bcsub($item['price'], $item['cost'], 4), '100', 4), $item['price'], 2)
    : 0;
?>
<div class="page-head">
  <div class="titles">
    <nav class="breadcrumb">
      <a href="/inventory">Inventory</a><span class="sep">/</span><span><?= View::e($item['name']) ?></span>
    </nav>
    <h1 class="h1"><?= View::e($item['name']) ?></h1>
    <p class="muted mono"><?= View::e($item['sku']) ?> · <?= View::e($item['barcode']) ?></p>
  </div>
  <a class="btn" href="/inventory"><svg aria-hidden="true"><use href="#i-arrow-left"></use></svg> Back</a>
</div>

<div class="grid cols-4">
  <div class="stat">
    <div class="stat-label">Retail price</div>
    <div class="stat-value"><?= View::e(Money::format($item['price'], $cur)) ?></div>
  </div>
  <div class="stat">
    <div class="stat-label">Avg. cost</div>
    <div class="stat-value"><?= View::e(Money::format($item['cost'], $cur)) ?></div>
    <div class="stat-delta muted">Weighted average</div>
  </div>
  <div class="stat">
    <div class="stat-label">Margin</div>
    <div class="stat-value"><?= View::e(number_format($margin, 1)) ?>%</div>
  </div>
  <div class="stat">
    <div class="stat-label">On hand</div>
    <div class="stat-value"><?= View::e((string) $item['on_hand']) ?></div>
    <div class="stat-delta <?= $low ? 'down' : 'up' ?>"><?= $low ? 'Below reorder point' : 'Healthy' ?></div>
  </div>
</div>

<div class="grid cols-2 mt-6">
  <div class="card">
    <div class="card-head"><div class="h3">Details</div></div>
    <div class="card-body grid" style="gap:var(--space-3)">
      <div class="row between"><span class="muted">Category</span><span class="strong"><?= View::e($item['category']) ?></span></div>
      <div class="row between"><span class="muted">Vendor</span>
        <span class="strong"><?= $vendor ? '<a style="color:var(--accent)" href="/vendors/' . View::e($vendor['id']) . '">' . View::e($vendor['name']) . '</a>' : '—' ?></span>
      </div>
      <div class="row between"><span class="muted">Reorder point</span><span class="strong tnum"><?= View::e((string) $item['reorder']) ?></span></div>
      <div class="row between"><span class="muted">Stock value</span><span class="strong tnum"><?= View::e(Money::format(bcmul($item['cost'], (string) $item['on_hand'], 4), $cur)) ?></span></div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Stock adjustment</div></div>
    <div class="card-body grid" style="gap:var(--space-4)">
      <div class="field">
        <label for="adj-qty">Quantity (+/−)</label>
        <input class="input" id="adj-qty" type="number" placeholder="e.g. 5 or -2">
      </div>
      <div class="field">
        <label for="adj-reason">Reason</label>
        <select class="select" id="adj-reason">
          <option>Received shipment</option>
          <option>Damaged / shrinkage</option>
          <option>Recount</option>
          <option>Return to vendor</option>
        </select>
      </div>
      <button class="btn btn-primary" type="button" onclick="alert('Mock: adjustment recorded. Wire to DBAL to persist.')">
        <svg aria-hidden="true"><use href="#i-check"></use></svg> Record adjustment
      </button>
    </div>
  </div>
</div>
