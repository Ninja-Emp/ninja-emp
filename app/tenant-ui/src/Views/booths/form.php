<?php
/**
 * Booth create/edit form.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\View;

$isEdit = $space !== null;
$action = $isEdit ? '/booths/' . $space['id'] : '/booths';
$statuses = ['available', 'reserved', 'leased', 'maintenance', 'inactive'];
$types = ['inline', 'endcap', 'kiosk', 'cart', 'island'];
?>
<div class="page-head">
  <div class="titles">
    <nav class="breadcrumb">
      <a href="/booths">Booths</a><span class="sep">/</span>
      <span><?= View::e($isEdit ? $space['code'] : 'New') ?></span>
    </nav>
    <h1 class="h1"><?= View::e($isEdit ? 'Edit booth ' . $space['code'] : 'New booth') ?></h1>
  </div>
  <a class="btn" href="/booths"><svg aria-hidden="true"><use href="#i-arrow-left"></use></svg> Back</a>
</div>

<form method="post" action="<?= View::e($action) ?>" class="grid" style="grid-template-columns: 2fr 1fr">
  <div class="card">
    <div class="card-head"><div class="h3">Booth details</div></div>
    <div class="card-body grid cols-2">
      <div class="field">
        <label for="code">Booth code</label>
        <input class="input" id="code" name="code" value="<?= View::e($space['code'] ?? '') ?>" placeholder="e.g. A-15" required>
      </div>
      <div class="field">
        <label for="type">Type</label>
        <select class="select" id="type" name="type">
          <?php foreach ($types as $t): ?>
            <option value="<?= View::e($t) ?>" <?= ($space['type'] ?? '') === $t ? 'selected' : '' ?>><?= View::e(ucfirst($t)) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
      <div class="field">
        <label for="sqft">Size (sq ft)</label>
        <input class="input" id="sqft" name="sqft" type="number" min="0" value="<?= View::e((string) ($space['sqft'] ?? '')) ?>">
      </div>
      <div class="field">
        <label for="rent">Monthly rent</label>
        <input class="input" id="rent" name="rent" inputmode="decimal" value="<?= View::e($space['rent'] ?? '') ?>" placeholder="0.00">
      </div>
      <div class="field">
        <label for="status">Status</label>
        <select class="select" id="status" name="status">
          <?php foreach ($statuses as $st): ?>
            <option value="<?= View::e($st) ?>" <?= ($space['status'] ?? '') === $st ? 'selected' : '' ?>><?= View::e(ucfirst($st)) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
      <div class="field">
        <label for="vendor_id">Assigned vendor</label>
        <select class="select" id="vendor_id" name="vendor_id">
          <option value="">— Unassigned —</option>
          <?php foreach ($vendors as $v): ?>
            <option value="<?= View::e($v['id']) ?>" <?= ($space['vendor_id'] ?? '') === $v['id'] ? 'selected' : '' ?>><?= View::e($v['name']) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
    </div>
    <div class="card-foot row between">
      <a class="btn btn-ghost" href="/booths">Cancel</a>
      <button class="btn btn-primary" type="submit"><svg aria-hidden="true"><use href="#i-check"></use></svg> <?= $isEdit ? 'Save changes' : 'Create booth' ?></button>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Map position</div></div>
    <div class="card-body grid cols-2">
      <div class="field"><label for="x">Column (x)</label><input class="input" id="x" name="x" type="number" min="1" value="<?= View::e((string) ($space['x'] ?? 1)) ?>"></div>
      <div class="field"><label for="y">Row (y)</label><input class="input" id="y" name="y" type="number" min="1" value="<?= View::e((string) ($space['y'] ?? 1)) ?>"></div>
      <div class="field"><label for="w">Width (cells)</label><input class="input" id="w" name="w" type="number" min="1" value="<?= View::e((string) ($space['w'] ?? 1)) ?>"></div>
      <div class="field"><label for="h">Height (cells)</label><input class="input" id="h" name="h" type="number" min="1" value="<?= View::e((string) ($space['h'] ?? 1)) ?>"></div>
      <p class="muted text-xs" style="grid-column:1/-1">Position drives the 2D booth map layout.</p>
    </div>
  </div>
</form>
