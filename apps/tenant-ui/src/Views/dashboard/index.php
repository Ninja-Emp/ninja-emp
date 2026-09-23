<?php
/**
 * Dashboard.
 *
 * @var View $this
 */
use NinjaEmp\TenantUi\Support\Money;
use NinjaEmp\TenantUi\Support\View;

$cur = $tenant['currency'];
$maxTrend = '0.0000';

foreach ($salesTrend as $d) {
    if (bccomp($d['amount'], $maxTrend, 4) > 0) {
        $maxTrend = $d['amount'];
    }
}
$last = $salesTrend[count($salesTrend) - 1]['amount'] ?? '0';
$prev = $salesTrend[count($salesTrend) - 2]['amount'] ?? '0';
$deltaPct = bccomp($prev, '0', 4) > 0 ? (float) bcdiv(bcmul(bcsub($last, $prev, 4), '100', 4), $prev, 2) : 0;
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Good afternoon, <?= View::e(explode(' ', $user['name'])[0]) ?></h1>
    <p class="muted">Here’s how <?= View::e($tenant['name']) ?> is doing today.</p>
  </div>
  <div class="row gap-2">
    <a class="btn" href="/reports"><svg aria-hidden="true"><use href="#i-report"></use></svg> Reports</a>
    <a class="btn btn-primary" href="/pos"><svg aria-hidden="true"><use href="#i-pos"></use></svg> Open POS</a>
  </div>
</div>

<!-- KPI row -->
<div class="grid cols-4">
  <div class="stat">
    <div class="stat-label"><svg style="width:16px;height:16px" aria-hidden="true"><use href="#i-wallet"></use></svg> Today’s sales</div>
    <div class="stat-value"><?= View::e(Money::format($todaySales, $cur)) ?></div>
    <div class="stat-delta <?= $deltaPct >= 0 ? 'up' : 'down' ?>">
      <?= $deltaPct >= 0 ? '▲' : '▼' ?> <?= View::e(number_format(abs($deltaPct), 1)) ?>% vs yesterday
    </div>
  </div>
  <div class="stat">
    <div class="stat-label"><svg style="width:16px;height:16px" aria-hidden="true"><use href="#i-vendor"></use></svg> Vendor payables</div>
    <div class="stat-value"><?= View::e(Money::format($vendorPayable, $cur)) ?></div>
    <div class="stat-delta muted">Owed across <?= count($vendors) ?> vendors</div>
  </div>
  <div class="stat">
    <div class="stat-label"><svg style="width:16px;height:16px" aria-hidden="true"><use href="#i-box"></use></svg> Inventory value</div>
    <div class="stat-value"><?= View::e(Money::format($inventoryValue, $cur)) ?></div>
    <div class="stat-delta muted">At weighted-average cost</div>
  </div>
  <div class="stat">
    <div class="stat-label"><svg style="width:16px;height:16px" aria-hidden="true"><use href="#i-alert"></use></svg> Low stock</div>
    <div class="stat-value"><?= View::e((string) $lowStockCount) ?></div>
    <div class="stat-delta <?= $lowStockCount > 0 ? 'down' : 'up' ?>">
      <?= $lowStockCount > 0 ? 'Needs reordering' : 'All good' ?>
    </div>
  </div>
</div>

<!-- Trend + occupancy -->
<div class="grid cols-2 mt-6" style="grid-template-columns: 2fr 1fr">
  <div class="card">
    <div class="card-head">
      <div>
        <div class="h3">Sales trend</div>
        <div class="text-sm muted">Last 14 days</div>
      </div>
      <span class="badge badge-accent"><?= View::e(Money::format($todaySales, $cur)) ?> today</span>
    </div>
    <div class="card-body">
      <div class="row" style="align-items:flex-end; gap:6px; height:180px">
        <?php foreach ($salesTrend as $i => $d): ?>
          <?php
            $h = bccomp($maxTrend, '0', 4) > 0
                ? (int) round((float) bcdiv(bcmul($d['amount'], '100', 4), $maxTrend, 2))
                : 0;
            $isLast = $i === count($salesTrend) - 1;
            ?>
          <div style="flex:1; display:flex; flex-direction:column; align-items:center; gap:6px; height:100%; justify-content:flex-end"
               title="<?= View::e($d['day']) ?>: <?= View::e(Money::format($d['amount'], $cur)) ?>">
            <div style="width:100%; height:<?= max(4, $h) ?>%; border-radius:6px 6px 0 0;
                        background: <?= $isLast ? 'var(--accent)' : 'var(--accent-soft)' ?>;
                        border:1px solid <?= $isLast ? 'var(--accent)' : 'var(--border)' ?>"></div>
            <span class="text-xs subtle" style="white-space:nowrap"><?= View::e(explode(' ', $d['day'])[1] ?? $d['day']) ?></span>
          </div>
        <?php endforeach; ?>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Booth occupancy</div></div>
    <div class="card-body">
      <div class="row between">
        <span class="h1"><?= View::e((string) $occupancy) ?>%</span>
        <span class="muted text-sm"><?= View::e((string) ($statusCounts['leased'] + $statusCounts['reserved'])) ?> / <?= View::e((string) $totalSpaces) ?> booths</span>
      </div>
      <div class="progress mt-4"><span style="width: <?= View::e((string) $occupancy) ?>%"></span></div>
      <div class="grid mt-6" style="gap:var(--space-3)">
        <?php
            $labels = ['leased' => ['Leased', 'badge-success'], 'available' => ['Available', 'badge-info'],
                       'reserved' => ['Reserved', 'badge-accent'], 'maintenance' => ['Maintenance', 'badge-warning'],
                       'inactive' => ['Inactive', '']];
?>
        <?php foreach ($labels as $key => [$label, $cls]): ?>
          <div class="row between">
            <span class="row gap-2"><span class="badge <?= $cls ?> badge-dot"><?= View::e($label) ?></span></span>
            <span class="strong tnum"><?= View::e((string) ($statusCounts[$key] ?? 0)) ?></span>
          </div>
        <?php endforeach; ?>
      </div>
    </div>
  </div>
</div>

<!-- Recent sales + low stock -->
<div class="grid cols-2 mt-6">
  <div class="card">
    <div class="card-head">
      <div class="h3">Recent sales</div>
      <a class="text-sm" style="color:var(--accent)" href="/reports">View all</a>
    </div>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th>Receipt</th><th>Time</th><th>Tender</th><th class="num">Total</th></tr></thead>
        <tbody>
          <?php foreach ($recentSales as $s): ?>
            <tr>
              <td class="mono strong"><?= View::e($s['no']) ?></td>
              <td class="muted"><?= View::e($s['time']) ?></td>
              <td>
                <?php foreach ($s['tenders'] as $t): ?>
                  <span class="badge"><?= View::e(ucwords(str_replace('_', ' ', $t))) ?></span>
                <?php endforeach; ?>
              </td>
              <td class="num strong"><?= View::e(Money::format($s['total'], $cur)) ?></td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  </div>

  <div class="card">
    <div class="card-head">
      <div class="h3">Low stock</div>
      <a class="text-sm" style="color:var(--accent)" href="/inventory">Manage</a>
    </div>
    <div class="table-wrap">
      <?php if (empty($lowStockItems)): ?>
        <div class="empty"><svg aria-hidden="true"><use href="#i-check"></use></svg><p>Everything is well stocked.</p></div>
      <?php else: ?>
        <table class="table">
          <thead><tr><th>Item</th><th class="num">On hand</th><th class="num">Reorder at</th></tr></thead>
          <tbody>
            <?php foreach ($lowStockItems as $it): ?>
              <tr>
                <td>
                  <a href="/inventory/<?= View::e($it['id']) ?>" class="strong"><?= View::e($it['name']) ?></a>
                  <div class="text-xs subtle mono"><?= View::e($it['sku']) ?></div>
                </td>
                <td class="num"><span class="badge badge-danger"><?= View::e((string) $it['on_hand']) ?></span></td>
                <td class="num muted"><?= View::e((string) $it['reorder']) ?></td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      <?php endif; ?>
    </div>
  </div>
</div>
