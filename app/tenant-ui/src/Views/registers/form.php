<?php
/**
 * Register create/edit form.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\View;

$isEdit = $register !== null;
$action = $isEdit ? '/registers/' . $register['id'] : '/registers';
?>
<div class="page-head">
  <div class="titles">
    <nav class="breadcrumb">
      <a href="/registers">Registers</a><span class="sep">/</span>
      <span><?= View::e($isEdit ? $register['name'] : 'New') ?></span>
    </nav>
    <h1 class="h1"><?= View::e($isEdit ? 'Edit register' : 'New register') ?></h1>
  </div>
  <a class="btn" href="/registers"><svg aria-hidden="true"><use href="#i-arrow-left"></use></svg> Back</a>
</div>

<form method="post" action="<?= View::e($action) ?>" class="grid" style="grid-template-columns: 2fr 1fr">
  <div class="card">
    <div class="card-head"><div class="h3">Register details</div></div>
    <div class="card-body grid cols-2">
      <div class="field" style="grid-column:1/-1">
        <label for="name">Name</label>
        <input class="input" id="name" name="name" value="<?= View::e($register['name'] ?? '') ?>" placeholder="e.g. Front Counter" required>
      </div>
      <div class="field" style="grid-column:1/-1">
        <label for="location">Location</label>
        <input class="input" id="location" name="location" value="<?= View::e($register['location'] ?? '') ?>" placeholder="e.g. Main Hall">
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Notes</div></div>
    <div class="card-body">
      <p class="muted text-sm">Registers are opened with an opening float and closed with a counted drawer total. Variance is computed automatically at close.</p>
    </div>
    <div class="card-foot row between">
      <a class="btn btn-ghost" href="/registers">Cancel</a>
      <button class="btn btn-primary" type="submit"><svg aria-hidden="true"><use href="#i-check"></use></svg> <?= $isEdit ? 'Save changes' : 'Create register' ?></button>
    </div>
  </div>
</form>
