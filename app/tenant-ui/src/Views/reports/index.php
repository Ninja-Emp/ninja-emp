<?php
/**
 * Reports.
 * @var \NinjaEmp\TenantUi\Support\View $this
 */
use NinjaEmp\TenantUi\Support\View;
use NinjaEmp\TenantUi\Support\Money;

$cur = $tenant['currency'];
$maxTrend = '0.0000';
foreach ($trend as $d) { if (bccomp($d['amount'], $maxTrend, 4) > 0) { $maxTrend = $d['amount']; } }
$tenderTotal = array_sum($tenderMix) ?: 1;
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Reports</h1>
    <p class="muted">Sales, vendor payouts, tax, and inventory valuation.</p>
  </div>
  <div class="row gap-2">
    <button class="btn" type="button" onclick="window.print()"><svg aria-hidden="true"><use href="#i-receipt"></use></svg> Print</button>
  </div>
</div>

<div class="grid cols-4">
  <div class="stat">
    <div class="stat-label">Today’s sales</div>
    <div class="stat-value"><?= View::e(Money::format($todaySales, $cur)) ?></div>
    <div class="stat-delta muted"><?= View::e((string) $salesCount) ?> transactions</div>
  </div>
  <div class="stat">
    <div class="stat-label">Inventory value</div>
    <div class="stat-value"><?= View::e(Money::format($inventoryValue, $cur)) ?></div>
    <div class="stat-delta muted">At cost</div>
  </div>
  <div class="stat">
    <div class="stat-label">Vendor payables</div>
    <div class="stat-value"><?= View::e(Money::format(array_sum(array_column($payouts, 'balance')) ?: '0', $cur)) ?></div>
    <div class="stat-delta muted"><?= View::e((string) count($payouts)) ?> vendors</div>
  </div>
  <div class="stat">
    <div class="stat-label">Tax collected</div>
    <div class="stat-value"><?= View::e(Money::format(bcmul($todaySales, '0.0825', 4), $cur)) ?></div>
    <div class="stat-delta muted">Est. at 8.25%</div>
  </div>
</div>

<div class="grid cols-2 mt-6" style="grid-template-columns: 2fr 1fr">
  <div class="card">
    <div class="card-head"><div class="h3">Sales — last 14 days</div></div>
    <div class="card-body">
      <div class="row" style="align-items:flex-end; gap:6px; height:200px">
        <?php foreach ($trend as $i => $d): ?>
          <?php
            $h = bccomp($maxTrend, '0', 4) > 0 ? (int) round((float) bcdiv(bcmul($d['amount'], '100', 4), $maxTrend, 2)) : 0;
            $isLast = $i === count($trend) - 1;
          ?>
          <div style="flex:1; display:flex; flex-direction:column; align-items:center; gap:6px; height:100%; justify-content:flex-end"
               title="<?= View::e($d['day']) ?>: <?= View::e(Money::format($d['amount'], $cur)) ?>">
            <div style="width:100%; height:<?= max(4, $h) ?>%; border-radius:6px 6px 0 0;
                        background: <?= $isLast ? 'var(--accent)' : 'var(--accent-soft)' ?>;
                        border:1px solid <?= $isLast ? 'var(--accent)' : 'var(--border)' ?>"></div>
            <span class="text-xs subtle"><?= View::e(explode(' ', $d['day'])[1] ?? $d['day']) ?></span>
          </div>
        <?php endforeach; ?>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Tender mix</div></div>
    <div class="card-body grid" style="gap:var(--space-4)">
      <?php foreach ($tenderMix as $tender => $count): ?>
        <?php $pct = (int) round($count / $tenderTotal * 100); ?>
        <div>
          <div class="row between text-sm"><span><?= View::e(ucwords(str_replace('_', ' ', $tender))) ?></span><span class="muted tnum"><?= View::e((string) $pct) ?>%</span></div>
          <div class="progress mt-2"><span style="width:<?= View::e((string) $pct) ?>%"></span></div>
        </div>
      <?php endforeach; ?>
    </div>
  </div>
</div>

<div class="grid cols-2 mt-6">
  <div class="card">
    <div class="card-head"><div class="h3">Vendor payouts</div></div>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th>Vendor</th><th>Type</th><th class="num">Balance owed</th></tr></thead>
        <tbody>
          <?php foreach ($payouts as $p): ?>
            <tr>
              <td class="strong"><?= View::e($p['name']) ?></td>
              <td><span class="badge"><?= View::e(ucfirst($p['type'])) ?></span></td>
              <td class="num strong tnum"><?= View::e(Money::format($p['balance'], $cur)) ?></td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  </div>

  <div class="card">
    <div class="card-head"><div class="h3">Tax rates</div></div>
    <div class="table-wrap">
      <table class="table">
        <thead><tr><th>Rate</th><th class="num">Percent</th></tr></thead>
        <tbody>
          <?php foreach ($taxRates as $t): ?>
            <tr>
              <td class="strong"><?= View::e($t['name']) ?></td>
              <td class="num tnum"><?= View::e(rtrim(rtrim($t['rate'], '0'), '.')) ?>%</td>
            </tr>
          <?php endforeach; ?>
        </tbody>
      </table>
    </div>
  </div>
</div>
