<?php
/**
 * Inventory list.
 * @var \NinjaEmp\TenantUi\Support\View $this
 */
use NinjaEmp\TenantUi\Support\View;
use NinjaEmp\TenantUi\Support\Money;

$cur = $tenant['currency'];
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Inventory</h1>
    <p class="muted">Items, stock levels, and weighted-average cost.</p>
  </div>
  <div class="row gap-2">
    <span class="badge badge-accent">Value <?= View::e(Money::format($inventoryValue, $cur)) ?></span>
    <?php if ($lowStockCount > 0): ?>
      <span class="badge badge-danger"><?= View::e((string) $lowStockCount) ?> low</span>
    <?php endif; ?>
    <a class="btn btn-primary" href="/inventory/new"><svg aria-hidden="true"><use href="#i-plus"></use></svg> New item</a>
  </div>
</div>

<div class="card">
  <div class="card-head">
    <form method="get" action="/inventory" class="row gap-2" style="flex:1; max-width:420px">
      <div style="position:relative; flex:1">
        <svg style="position:absolute;left:12px;top:50%;transform:translateY(-50%);width:16px;height:16px;color:var(--text-subtle)" aria-hidden="true"><use href="#i-search"></use></svg>
        <input class="input" name="q" value="<?= View::e($query) ?>" placeholder="Search items…" style="padding-left:38px">
      </div>
      <button class="btn" type="submit">Search</button>
    </form>
    <span class="text-sm muted"><?= View::e((string) count($items)) ?> items</span>
  </div>
  <div class="table-wrap">
    <?php if (empty($items)): ?>
      <div class="empty"><svg aria-hidden="true"><use href="#i-search"></use></svg><p>No items match your search.</p></div>
    <?php else: ?>
      <table class="table">
        <thead>
          <tr><th>Item</th><th>Category</th><th>Owner</th><th>Vendor</th><th class="num">Price</th><th class="num">Cost</th><th class="num">On hand</th><th>Stock</th><th></th></tr>
        </thead>
        <tbody>
          <?php foreach ($items as $it): ?>
            <?php $low = $it['on_hand'] <= $it['reorder']; ?>
            <tr>
              <td>
                <a class="strong" href="/inventory/<?= View::e($it['id']) ?>"><?= View::e($it['name']) ?></a>
                <div class="text-xs subtle mono"><?= View::e($it['sku']) ?> · <?= View::e($it['barcode']) ?></div>
              </td>
              <td><span class="badge"><?= View::e($it['category']) ?></span></td>
              <td>
                <?php if (($it['owner'] ?? 'vendor') === 'store'): ?>
                  <span class="badge badge-accent">Store</span>
                <?php else: ?>
                  <span class="badge">Vendor</span>
                <?php endif; ?>
              </td>
              <td class="muted"><?= View::e($vendorNames[$it['vendor_id']] ?? '—') ?></td>
              <td class="num tnum"><?= View::e(Money::format($it['price'], $cur)) ?></td>
              <td class="num tnum muted"><?= View::e(Money::format($it['cost'], $cur)) ?></td>
              <td class="num strong tnum"><?= View::e((string) $it['on_hand']) ?></td>
              <td>
                <?php if ($low): ?>
                  <span class="badge badge-danger badge-dot">Low</span>
                <?php else: ?>
                  <span class="badge badge-success badge-dot">OK</span>
                <?php endif; ?>
              </td>
              <td class="num">
                <a class="btn btn-sm btn-ghost" href="/inventory/<?= View::e($it['id']) ?>/edit"><svg aria-hidden="true"><use href="#i-edit"></use></svg> Edit</a>
              </td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    <?php endif; ?>
  </div>
</div>
