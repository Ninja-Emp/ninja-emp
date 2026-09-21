<?php
/**
 * Registers list — create, open, close.
 * @var \NinjaEmp\TenantUi\Support\View $this
 */
use NinjaEmp\TenantUi\Support\View;
use NinjaEmp\TenantUi\Support\Money;

$cur = $tenant['currency'];
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Registers</h1>
    <p class="muted">Create registers, open them with a float, and close them with a count.</p>
  </div>
  <a class="btn btn-primary" href="/registers/new"><svg aria-hidden="true"><use href="#i-plus"></use></svg> New register</a>
</div>

<div class="grid cols-2">
  <?php foreach ($registers as $r): ?>
    <?php $isOpen = $r['status'] === 'open'; ?>
    <div class="card">
      <div class="card-head">
        <div class="h3"><?= View::e($r['name']) ?></div>
        <span class="badge <?= $isOpen ? 'badge-success' : '' ?> badge-dot"><?= View::e(ucfirst($r['status'])) ?></span>
      </div>
      <div class="card-body grid" style="gap:var(--space-3)">
        <div class="row between"><span class="muted">Cashier</span><span class="strong"><?= View::e($r['cashier'] ?? '—') ?></span></div>
        <div class="row between"><span class="muted">Opened</span><span class="strong"><?= View::e($r['opened'] ?? '—') ?></span></div>
        <div class="row between"><span class="muted">Opening float</span><span class="tnum"><?= View::e(Money::format($r['float'] ?? '0.0000', $cur)) ?></span></div>
        <div class="row between"><span class="muted">Drawer (expected)</span><span class="tnum strong"><?= View::e(Money::format($r['drawer'] ?? '0.0000', $cur)) ?></span></div>
        <?php if (!empty($r['counted'])): ?>
          <div class="row between"><span class="muted">Counted</span><span class="tnum"><?= View::e(Money::format($r['counted'], $cur)) ?></span></div>
          <div class="row between">
            <span class="muted">Variance</span>
            <?php $v = (float) $r['variance']; ?>
            <span class="tnum strong" style="color:<?= $v == 0.0 ? 'var(--success)' : 'var(--danger)' ?>"><?= View::e(Money::format($r['variance'], $cur)) ?></span>
          </div>
        <?php endif; ?>
      </div>
      <div class="card-foot row between">
        <a class="btn btn-sm btn-ghost" href="/registers/<?= View::e($r['id']) ?>/edit"><svg aria-hidden="true"><use href="#i-edit"></use></svg> Rename</a>
        <?php if ($isOpen): ?>
          <button class="btn btn-sm" type="button" data-open-modal="close-<?= View::e($r['id']) ?>">Close register</button>
        <?php else: ?>
          <button class="btn btn-sm btn-primary" type="button" data-open-modal="open-<?= View::e($r['id']) ?>">Open register</button>
        <?php endif; ?>
      </div>
    </div>

    <!-- Open modal -->
    <div class="modal" id="open-<?= View::e($r['id']) ?>" hidden>
      <div class="modal-panel" role="dialog" aria-modal="true">
        <div class="card-head"><div class="h3">Open <?= View::e($r['name']) ?></div>
          <button class="icon-btn" type="button" data-close-modal aria-label="Close"><svg aria-hidden="true"><use href="#i-x"></use></svg></button>
        </div>
        <form method="post" action="/registers/<?= View::e($r['id']) ?>/open">
          <div class="card-body grid" style="gap:var(--space-4)">
            <div class="field">
              <label for="cashier-<?= View::e($r['id']) ?>">Cashier</label>
              <input class="input" id="cashier-<?= View::e($r['id']) ?>" name="cashier" value="<?= View::e($user['name'] ?? '') ?>">
            </div>
            <div class="field">
              <label for="float-<?= View::e($r['id']) ?>">Opening float</label>
              <input class="input" id="float-<?= View::e($r['id']) ?>" name="float" inputmode="decimal" value="200.00">
            </div>
          </div>
          <div class="card-foot row between">
            <button class="btn btn-ghost" type="button" data-close-modal>Cancel</button>
            <button class="btn btn-primary" type="submit">Open register</button>
          </div>
        </form>
      </div>
    </div>

    <!-- Close modal -->
    <div class="modal" id="close-<?= View::e($r['id']) ?>" hidden>
      <div class="modal-panel" role="dialog" aria-modal="true">
        <div class="card-head"><div class="h3">Close <?= View::e($r['name']) ?></div>
          <button class="icon-btn" type="button" data-close-modal aria-label="Close"><svg aria-hidden="true"><use href="#i-x"></use></svg></button>
        </div>
        <form method="post" action="/registers/<?= View::e($r['id']) ?>/close">
          <div class="card-body grid" style="gap:var(--space-4)">
            <p class="muted text-sm">Enter the counted drawer total. Variance is computed against the expected drawer.</p>
            <div class="field">
              <label for="counted-<?= View::e($r['id']) ?>">Counted total</label>
              <input class="input" id="counted-<?= View::e($r['id']) ?>" name="counted" inputmode="decimal" value="<?= View::e($r['drawer'] ?? '0.00') ?>">
            </div>
          </div>
          <div class="card-foot row between">
            <button class="btn btn-ghost" type="button" data-close-modal>Cancel</button>
            <button class="btn btn-primary" type="submit">Close register</button>
          </div>
        </form>
      </div>
    </div>
  <?php endforeach; ?>
</div>

<script>
  (function () {
    document.querySelectorAll('[data-open-modal]').forEach(function (b) {
      b.addEventListener('click', function () {
        var m = document.getElementById(b.getAttribute('data-open-modal'));
        if (m) m.hidden = false;
      });
    });
    document.querySelectorAll('[data-close-modal]').forEach(function (b) {
      b.addEventListener('click', function () { b.closest('.modal').hidden = true; });
    });
    document.querySelectorAll('.modal').forEach(function (m) {
      m.addEventListener('click', function (e) { if (e.target === m) m.hidden = true; });
    });
  })();
</script>
