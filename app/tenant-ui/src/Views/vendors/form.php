<?php
/**
 * Vendor create/edit form.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\View;

$isEdit = $vendor !== null;
$action = $isEdit ? '/vendors/' . $vendor['id'] : '/vendors';
$types = ['consignor', 'vendor'];
$statuses = ['active', 'paused', 'inactive'];
?>
<div class="page-head">
  <div class="titles">
    <nav class="breadcrumb">
      <a href="/vendors">Vendors</a><span class="sep">/</span>
      <span><?= View::e($isEdit ? $vendor['name'] : 'New') ?></span>
    </nav>
    <h1 class="h1"><?= View::e($isEdit ? 'Edit vendor' : 'New vendor') ?></h1>
  </div>
  <a class="btn" href="/vendors"><svg aria-hidden="true"><use href="#i-arrow-left"></use></svg> Back</a>
</div>

<form method="post" action="<?= View::e($action) ?>" class="grid" style="grid-template-columns: 2fr 1fr">
  <div class="card">
    <div class="card-head"><div class="h3">Vendor details</div></div>
    <div class="card-body grid cols-2">
      <div class="field" style="grid-column:1/-1">
        <label for="name">Business name</label>
        <input class="input" id="name" name="name" value="<?= View::e($vendor['name'] ?? '') ?>" placeholder="e.g. The Quilt Corner" required>
      </div>
      <div class="field">
        <label for="contact">Contact name</label>
        <input class="input" id="contact" name="contact" value="<?= View::e($vendor['contact'] ?? '') ?>">
      </div>
      <div class="field">
        <label for="phone">Phone</label>
        <input class="input" id="phone" name="phone" value="<?= View::e($vendor['phone'] ?? '') ?>">
      </div>
      <div class="field" style="grid-column:1/-1">
        <label for="email">Email</label>
        <input class="input" id="email" name="email" type="email" value="<?= View::e($vendor['email'] ?? '') ?>">
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Terms</div></div>
    <div class="card-body grid cols-2">
      <div class="field">
        <label for="type">Type</label>
        <select class="select" id="type" name="type">
          <?php foreach ($types as $t): ?>
            <option value="<?= View::e($t) ?>" <?= ($vendor['type'] ?? '') === $t ? 'selected' : '' ?>><?= View::e(ucfirst($t)) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
      <div class="field">
        <label for="status">Status</label>
        <select class="select" id="status" name="status">
          <?php foreach ($statuses as $st): ?>
            <option value="<?= View::e($st) ?>" <?= ($vendor['status'] ?? '') === $st ? 'selected' : '' ?>><?= View::e(ucfirst($st)) ?></option>
          <?php endforeach; ?>
        </select>
      </div>
      <div class="field" style="grid-column:1/-1">
        <label for="commission">Commission (%)</label>
        <input class="input" id="commission" name="commission" inputmode="decimal" value="<?= View::e($vendor['commission'] ?? '20.0000') ?>">
      </div>
    </div>
    <div class="card-foot row between">
      <a class="btn btn-ghost" href="/vendors">Cancel</a>
      <button class="btn btn-primary" type="submit"><svg aria-hidden="true"><use href="#i-check"></use></svg> <?= $isEdit ? 'Save changes' : 'Create vendor' ?></button>
    </div>
  </div>
</form>
