<?php
/**
 * Inventory item create/edit form.
 * @var \NinjaEmp\TenantUi\Support\View $this
 */
use NinjaEmp\TenantUi\Support\View;

$isEdit = $item !== null;
$action = $isEdit ? '/inventory/' . $item['id'] : '/inventory';
$owner = $item['owner'] ?? 'vendor';
$categories = ['Food', 'Bath', 'Home', 'Antiques', 'Apparel', 'Crafts', 'General'];
?>
<div class="page-head">
  <div class="titles">
    <nav class="breadcrumb">
      <a href="/inventory">Inventory</a><span class="sep">/</span>
      <span><?= View::e($isEdit ? $item['name'] : 'New') ?></span>
    </nav>
    <h1 class="h1"><?= View::e($isEdit ? 'Edit item' : 'New item') ?></h1>
  </div>
  <a class="btn" href="/inventory"><svg aria-hidden="true"><use href="#i-arrow-left"></use></svg> Back</a>
</div>

<form method="post" action="<?= View::e($action) ?>" class="grid" style="grid-template-columns: 2fr 1fr">
  <div class="card">
    <div class="card-head"><div class="h3">Item details</div></div>
    <div class="card-body grid cols-2">
      <div class="field" style="grid-column:1/-1">
        <label for="name">Name</label>
        <input class="input" id="name" name="name" value="<?= View::e($item['name'] ?? '') ?>" placeholder="e.g. Blueberry Jam (large jar)" required>
      </div>
      <div class="field">
        <label for="sku">SKU</label>
        <input class="input" id="sku" name="sku" value="<?= View::e($item['sku'] ?? '') ?>" placeholder="e.g. JAM-BLU-L">
      </div>
      <div class="field">
        <label for="barcode">Barcode</label>
        <input class="input" id="barcode" name="barcode" value="<?= View::e($item['barcode'] ?? '') ?>" placeholder="Scan or type">
      </div>
      <div class="field">
        <label for="category">Category</label>
        <select class="select" id="category" name="category">
          <?php foreach ($categories as $c): ?>
            <option value="<?= View::e($c) ?>" <?= ($item['category'] ?? '') === $c ? 'selected' : '' ?>><?= View::e($c) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
      <div class="field">
        <label for="owner">Ownership</label>
        <select class="select" id="owner" name="owner" data-owner-select>
          <option value="vendor" <?= $owner === 'vendor' ? 'selected' : '' ?>>Vendor-owned (consignment)</option>
          <option value="store"  <?= $owner === 'store'  ? 'selected' : '' ?>>Store-owned</option>
        </select>
      </div>
      <div class="field" data-vendor-field <?= $owner === 'store' ? 'hidden' : '' ?>>
        <label for="vendor_id">Vendor</label>
        <select class="select" id="vendor_id" name="vendor_id">
          <option value="">— Unassigned —</option>
          <?php foreach ($vendors as $v): ?>
            <option value="<?= View::e($v['id']) ?>" <?= ($item['vendor_id'] ?? '') === $v['id'] ? 'selected' : '' ?>><?= View::e($v['name']) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Pricing &amp; stock</div></div>
    <div class="card-body grid cols-2">
      <div class="field">
        <label for="price">Retail price</label>
        <input class="input" id="price" name="price" inputmode="decimal" value="<?= View::e($item['price'] ?? '') ?>" placeholder="0.00">
      </div>
      <div class="field">
        <label for="cost">Cost</label>
        <input class="input" id="cost" name="cost" inputmode="decimal" value="<?= View::e($item['cost'] ?? '') ?>" placeholder="0.00">
      </div>
      <div class="field">
        <label for="on_hand">On hand</label>
        <input class="input" id="on_hand" name="on_hand" type="number" min="0" value="<?= View::e((string) ($item['on_hand'] ?? 0)) ?>">
      </div>
      <div class="field">
        <label for="reorder">Reorder at</label>
        <input class="input" id="reorder" name="reorder" type="number" min="0" value="<?= View::e((string) ($item['reorder'] ?? 0)) ?>">
      </div>
    </div>
    <div class="card-foot row between">
      <a class="btn btn-ghost" href="/inventory">Cancel</a>
      <button class="btn btn-primary" type="submit"><svg aria-hidden="true"><use href="#i-check"></use></svg> <?= $isEdit ? 'Save changes' : 'Create item' ?></button>
    </div>
  </div>
</form>

<script>
  (function () {
    var sel = document.querySelector('[data-owner-select]');
    var field = document.querySelector('[data-vendor-field]');
    if (!sel || !field) return;
    function sync() { field.hidden = sel.value === 'store'; }
    sel.addEventListener('change', sync);
    sync();
  })();
</script>
