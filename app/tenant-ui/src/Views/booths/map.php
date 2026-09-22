<?php
/**
 * 2D booth map.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\Money;
use NinjaEmp\TenantUi\Support\View;

$cur = $tenant['currency'];
$statusColor = [
    'leased' => 'var(--success)', 'available' => 'var(--info)', 'reserved' => 'var(--accent)',
    'maintenance' => 'var(--warning)', 'inactive' => 'var(--text-subtle)',
];
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Booth Map</h1>
    <p class="muted">Click a booth to view or edit. Keyboard: Tab to a booth, Enter to open.</p>
  </div>
  <div class="row gap-2">
    <a class="btn" href="/booths"><svg aria-hidden="true"><use href="#i-booth"></use></svg> List view</a>
    <a class="btn btn-primary" href="/booths/new"><svg aria-hidden="true"><use href="#i-plus"></use></svg> New booth</a>
  </div>
</div>

<div class="grid" style="grid-template-columns: 1fr 300px">
  <div class="card">
    <div class="card-head">
      <div class="h3">Main Floor</div>
      <div class="row gap-3 text-xs">
        <?php foreach ($statusColor as $k => $c): ?>
          <span class="row gap-2"><span style="width:10px;height:10px;border-radius:3px;background:<?= View::e($c) ?>"></span><?= View::e(ucfirst($k)) ?></span>
        <?php endforeach; ?>
      </div>
    </div>
    <div class="card-body">
      <div class="booth-map" id="booth-map" role="application" aria-label="Interactive booth map">
        <?php foreach ($spaces as $s): ?>
          <?php
            $cell = 56;
            $gap = 8;
            $left = ($s['x'] - 1) * ($cell + $gap);
            $top = ($s['y'] - 1) * ($cell + $gap);
            $w = $s['w'] * $cell + ($s['w'] - 1) * $gap;
            $h = $s['h'] * $cell + ($s['h'] - 1) * $gap;
            $vendor = $s['vendor_id'] && isset($vendorNames[$s['vendor_id']]) ? $vendorNames[$s['vendor_id']] : 'Unassigned';
            ?>
          <a class="booth-cell"
             href="/booths/<?= View::e($s['id']) ?>"
             style="left:<?= $left ?>px; top:<?= $top ?>px; width:<?= $w ?>px; height:<?= $h ?>px;
                    border-color: <?= View::e($statusColor[$s['status']] ?? 'var(--border)') ?>"
             data-booth="<?= View::e($s['id']) ?>"
             data-code="<?= View::e($s['code']) ?>"
             data-status="<?= View::e($s['status']) ?>"
             data-vendor="<?= View::e($vendor) ?>"
             data-rent="<?= View::e(Money::format($s['rent'], $cur)) ?>"
             title="<?= View::e($s['code'] . ' · ' . ucfirst($s['status']) . ' · ' . $vendor) ?>">
            <span class="booth-code"><?= View::e($s['code']) ?></span>
            <span class="booth-dot" style="background:<?= View::e($statusColor[$s['status']] ?? 'var(--border)') ?>"></span>
          </a>
        <?php endforeach; ?>
      </div>
    </div>
  </div>

  <div class="card" id="booth-detail">
    <div class="card-head"><div class="h3">Booth details</div></div>
    <div class="card-body">
      <div class="empty" id="booth-detail-empty">
        <svg aria-hidden="true"><use href="#i-map"></use></svg>
        <p>Select a booth on the map to see its details.</p>
      </div>
      <div id="booth-detail-body" hidden>
        <div class="h2 mono" id="bd-code"></div>
        <div class="mt-4 grid" style="gap:var(--space-3)">
          <div class="row between"><span class="muted">Status</span><span id="bd-status"></span></div>
          <div class="row between"><span class="muted">Vendor</span><span class="strong" id="bd-vendor"></span></div>
          <div class="row between"><span class="muted">Monthly rent</span><span class="strong tnum" id="bd-rent"></span></div>
        </div>
        <a class="btn btn-primary btn-block mt-6" id="bd-edit" href="#"><svg aria-hidden="true"><use href="#i-edit"></use></svg> Edit booth</a>
      </div>
    </div>
  </div>
</div>
