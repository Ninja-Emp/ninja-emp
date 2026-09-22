<?php
/**
 * Vendor detail.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\Money;
use NinjaEmp\TenantUi\Support\View;

$cur = $tenant['currency'];
?>
<div class="page-head">
  <div class="titles">
    <nav class="breadcrumb">
      <a href="/vendors">Vendors</a><span class="sep">/</span><span><?= View::e($vendor['name']) ?></span>
    </nav>
    <h1 class="h1"><?= View::e($vendor['name']) ?></h1>
    <p class="muted"><?= View::e(ucfirst($vendor['type'])) ?> · since <?= View::e($vendor['since']) ?></p>
  </div>
  <div class="row gap-2">
    <span class="badge <?= $vendor['status'] === 'active' ? 'badge-success' : 'badge-warning' ?> badge-dot"><?= View::e(ucfirst($vendor['status'])) ?></span>
    <a class="btn" href="/vendors/<?= View::e($vendor['id']) ?>/edit"><svg aria-hidden="true"><use href="#i-edit"></use></svg> Edit</a>
    <a class="btn" href="/vendors"><svg aria-hidden="true"><use href="#i-arrow-left"></use></svg> Back</a>
  </div>
</div>

<div class="grid cols-4">
  <div class="stat">
    <div class="stat-label">Balance owed</div>
    <div class="stat-value"><?= View::e(Money::format($vendor['balance'], $cur)) ?></div>
    <div class="stat-delta muted">Realtime payable</div>
  </div>
  <div class="stat">
    <div class="stat-label">Commission</div>
    <div class="stat-value"><?= View::e(rtrim(rtrim($vendor['commission'], '0'), '.')) ?>%</div>
    <div class="stat-delta muted">Per agreement</div>
  </div>
  <div class="stat">
    <div class="stat-label">Items</div>
    <div class="stat-value"><?= View::e((string) count($items)) ?></div>
    <div class="stat-delta muted">In inventory</div>
  </div>
  <div class="stat">
    <div class="stat-label">Booths</div>
    <div class="stat-value"><?= View::e((string) count($spaces)) ?></div>
    <div class="stat-delta muted"><?= View::e(implode(', ', array_column($spaces, 'code')) ?: 'None') ?></div>
  </div>
</div>

<div class="grid cols-2 mt-6" style="grid-template-columns: 1fr 1fr">
  <div class="card">
    <div class="card-head"><div class="h3">Contact</div></div>
    <div class="card-body grid" style="gap:var(--space-3)">
      <div class="row between"><span class="muted">Contact</span><span class="strong"><?= View::e($vendor['contact']) ?></span></div>
      <div class="row between"><span class="muted">Email</span><a style="color:var(--accent)" href="mailto:<?= View::e($vendor['email']) ?>"><?= View::e($vendor['email']) ?></a></div>
      <div class="row between"><span class="muted">Phone</span><span class="strong"><?= View::e($vendor['phone']) ?></span></div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Items</div></div>
    <div class="table-wrap">
      <?php if (empty($items)): ?>
        <div class="empty"><p>No items on file.</p></div>
      <?php else: ?>
        <table class="table">
          <thead><tr><th>Item</th><th class="num">Price</th><th class="num">On hand</th></tr></thead>
          <tbody>
            <?php foreach ($items as $it): ?>
              <tr>
                <td><a href="/inventory/<?= View::e($it['id']) ?>" class="strong"><?= View::e($it['name']) ?></a><div class="text-xs subtle mono"><?= View::e($it['sku']) ?></div></td>
                <td class="num tnum"><?= View::e(Money::format($it['price'], $cur)) ?></td>
                <td class="num tnum"><?= View::e((string) $it['on_hand']) ?></td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      <?php endif; ?>
    </div>
  </div>
</div>

<div class="card mt-6">
  <div class="card-head">
    <div class="h3">Buy from vendor</div>
    <span class="text-sm muted">Purchase stock — creates a store-owned item and increases the payable</span>
  </div>
  <form method="post" action="/vendors/<?= View::e($vendor['id']) ?>/purchase">
    <div class="card-body grid cols-2" style="gap:var(--space-4)">
      <div class="field" style="grid-column:1/-1">
        <label for="buy-name">Item name</label>
        <input class="input" id="buy-name" name="name" placeholder="e.g. Assorted soaps (case)" required>
      </div>
      <div class="field">
        <label for="buy-cost">Unit cost</label>
        <input class="input" id="buy-cost" name="cost" inputmode="decimal" placeholder="0.00" required>
      </div>
      <div class="field">
        <label for="buy-price">Retail price</label>
        <input class="input" id="buy-price" name="price" inputmode="decimal" placeholder="0.00">
      </div>
      <div class="field">
        <label for="buy-qty">Quantity</label>
        <input class="input" id="buy-qty" name="qty" type="number" min="1" value="1">
      </div>
      <div class="field">
        <label for="buy-sku">SKU</label>
        <input class="input" id="buy-sku" name="sku" placeholder="Optional">
      </div>
    </div>
    <div class="card-foot row between">
      <span class="text-sm muted">The vendor payable increases by cost × quantity.</span>
      <button class="btn btn-primary" type="submit"><svg aria-hidden="true"><use href="#i-check"></use></svg> Record purchase</button>
    </div>
  </form>
</div>

<div class="card mt-6">
  <div class="card-head">
    <div class="h3">Statement</div>
    <span class="text-sm muted">Recent sales activity</span>
  </div>
  <div class="table-wrap">
    <?php if (empty($statement)): ?>
      <div class="empty"><p>No sales activity yet.</p></div>
    <?php else: ?>
      <table class="table">
        <thead><tr><th>Receipt</th><th>Time</th><th>Item</th><th class="num">Gross</th><th class="num">Commission</th><th class="num">Net to vendor</th></tr></thead>
        <tbody>
          <?php foreach ($statement as $row): ?>
            <tr>
              <td class="mono strong"><?= View::e($row['no']) ?></td>
              <td class="muted"><?= View::e($row['time']) ?></td>
              <td><?= View::e($row['item']) ?></td>
              <td class="num tnum"><?= View::e(Money::format($row['gross'], $cur)) ?></td>
              <td class="num tnum" style="color:var(--danger)">-<?= View::e(Money::format($row['commission'], $cur)) ?></td>
              <td class="num strong tnum"><?= View::e(Money::format($row['net'], $cur)) ?></td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    <?php endif; ?>
  </div>
</div>
