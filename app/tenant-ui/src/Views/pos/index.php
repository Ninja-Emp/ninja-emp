<?php
/**
 * Point of Sale.
 * @var \NinjaEmp\TenantUi\Support\View $this
 */
use NinjaEmp\TenantUi\Support\View;
use NinjaEmp\TenantUi\Support\Money;

$cur = $tenant['currency'];
$taxTotal = '0.0000';
foreach ($taxRates as $t) { $taxTotal = bcadd($taxTotal, $t['rate'], 4); }
?>
<div class="page-head">
  <div class="titles">
    <h1 class="h1">Point of Sale</h1>
    <p class="muted">Scan or search to add items. Keyboard-first: <kbd class="mono">F2</kbd> scan, <kbd class="mono">F4</kbd> pay, <kbd class="mono">F8</kbd> hold.</p>
  </div>
  <div class="row gap-2">
    <span class="badge badge-success badge-dot">Register open · <?= View::e($registers[0]['cashier'] ?? '—') ?></span>
  </div>
</div>

<div class="pos" id="pos" data-currency="<?= View::e($cur) ?>" data-tax-rate="<?= View::e($taxTotal) ?>">
  <!-- Left: catalog + scan -->
  <div class="pos-left">
    <div class="card">
      <div class="card-body">
        <div class="field">
          <label for="scan">Scan barcode or enter SKU</label>
          <div class="row gap-2">
            <div style="position:relative; flex:1">
              <svg style="position:absolute;left:12px;top:50%;transform:translateY(-50%);width:18px;height:18px;color:var(--text-subtle)" aria-hidden="true"><use href="#i-barcode"></use></svg>
              <input class="input" id="scan" style="padding-left:40px" placeholder="Scan or type a code, then Enter" autocomplete="off" autofocus>
            </div>
            <button class="btn btn-primary" type="button" id="scan-btn">Add</button>
          </div>
          <div class="text-xs subtle" id="scan-msg" role="status" aria-live="polite"></div>
        </div>
      </div>
    </div>

    <div class="card mt-4">
      <div class="card-head">
        <div class="h3">Catalog</div>
        <input class="input" id="catalog-search" placeholder="Filter items…" style="max-width:220px;height:34px">
      </div>
      <div class="card-body" style="max-height:calc(100vh - 340px); overflow:auto">
        <div class="pos-grid" id="catalog">
          <?php foreach ($items as $it): ?>
            <button class="pos-tile" type="button"
                    data-add-item
                    data-id="<?= View::e($it['id']) ?>"
                    data-name="<?= View::e($it['name']) ?>"
                    data-sku="<?= View::e($it['sku']) ?>"
                    data-price="<?= View::e($it['price']) ?>"
                    data-vendor="<?= View::e($it['vendor_id']) ?>"
                    data-search="<?= View::e(strtolower($it['name'] . ' ' . $it['sku'] . ' ' . $it['category'])) ?>">
              <span class="pos-tile-name"><?= View::e($it['name']) ?></span>
              <span class="pos-tile-meta">
                <span class="mono text-xs subtle"><?= View::e($it['sku']) ?></span>
                <span class="strong"><?= View::e(Money::format($it['price'], $cur)) ?></span>
              </span>
              <?php if ($it['on_hand'] <= $it['reorder']): ?>
                <span class="badge badge-danger" style="position:absolute;top:8px;right:8px">Low</span>
              <?php endif; ?>
            </button>
          <?php endforeach; ?>
        </div>
      </div>
    </div>
  </div>

  <!-- Right: cart + totals -->
  <div class="pos-right">
    <div class="card pos-cart">
      <div class="card-head">
        <div class="h3">Current sale</div>
        <button class="btn btn-sm btn-ghost" type="button" id="clear-cart">
          <svg aria-hidden="true"><use href="#i-trash"></use></svg> Clear
        </button>
      </div>
      <div class="pos-lines" id="cart-lines">
        <div class="empty" id="cart-empty">
          <svg aria-hidden="true"><use href="#i-cart"></use></svg>
          <p>No items yet. Scan or tap a product to begin.</p>
        </div>
      </div>

      <div class="pos-totals">
        <div class="row between"><span class="muted">Subtotal</span><span class="tnum" id="t-subtotal">$0.00</span></div>
        <div class="row between" id="row-discount" hidden>
          <span class="muted">Discount <span class="text-xs subtle" id="discount-label"></span></span>
          <span class="tnum" style="color:var(--danger)" id="t-discount">-$0.00</span>
        </div>
        <div class="row between" id="row-tax">
          <span class="muted">Tax <span class="text-xs subtle">(<?= View::e(rtrim(rtrim($taxTotal, '0'), '.')) ?>%)</span></span>
          <span class="tnum" id="t-tax">$0.00</span>
        </div>
        <div class="row between" id="row-taxfree" hidden>
          <span class="badge badge-warning">Tax waived</span>
          <span class="text-xs subtle" id="taxfree-reason"></span>
        </div>
        <div class="row between pos-grand">
          <span class="strong">Total</span>
          <span class="h2 tnum" id="t-total">$0.00</span>
        </div>
      </div>

      <div class="pos-actions">
        <button class="btn" type="button" id="btn-discount"><svg aria-hidden="true"><use href="#i-percent"></use></svg> Discount</button>
        <button class="btn" type="button" id="btn-taxfree"><svg aria-hidden="true"><use href="#i-shield"></use></svg> Tax-free</button>
        <button class="btn" type="button" id="btn-hold"><svg aria-hidden="true"><use href="#i-pause"></use></svg> Hold</button>
        <button class="btn btn-primary btn-lg btn-block" type="button" id="btn-pay" style="grid-column:1 / -1">
          <svg aria-hidden="true"><use href="#i-wallet"></use></svg> Charge <span id="pay-amount">$0.00</span>
        </button>
      </div>
    </div>

    <!-- Held sales -->
    <div class="card mt-4" id="held-card" hidden>
      <div class="card-head"><div class="h3">Held sales</div></div>
      <div class="card-body" id="held-list"></div>
    </div>
  </div>
</div>

<!-- Discount modal -->
<div class="modal" id="discount-modal" hidden>
  <div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="discount-title">
    <div class="card-head"><div class="h3" id="discount-title">Apply discount</div>
      <button class="icon-btn" type="button" data-close-modal aria-label="Close"><svg aria-hidden="true"><use href="#i-x"></use></svg></button>
    </div>
    <div class="card-body grid" style="gap:var(--space-4)">
      <div class="field">
        <label>Type</label>
        <div class="segmented" id="discount-type">
          <button type="button" data-dtype="percent" aria-pressed="true">Percent</button>
          <button type="button" data-dtype="amount" aria-pressed="false">Amount</button>
        </div>
      </div>
      <div class="field">
        <label for="discount-value">Value</label>
        <input class="input" id="discount-value" type="text" inputmode="decimal" placeholder="e.g. 10">
      </div>
      <div class="field">
        <label for="discount-reason">Reason</label>
        <select class="select" id="discount-reason">
          <option>Manager approval</option>
          <option>Damaged item</option>
          <option>Loyalty</option>
          <option>Promotion</option>
          <option>Other</option>
        </select>
      </div>
    </div>
    <div class="card-foot row between">
      <button class="btn btn-ghost" type="button" id="discount-remove">Remove discount</button>
      <button class="btn btn-primary" type="button" id="discount-apply">Apply</button>
    </div>
  </div>
</div>

<!-- Tax-free modal -->
<div class="modal" id="taxfree-modal" hidden>
  <div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="taxfree-title">
    <div class="card-head"><div class="h3" id="taxfree-title">Tax-free sale</div>
      <button class="icon-btn" type="button" data-close-modal aria-label="Close"><svg aria-hidden="true"><use href="#i-x"></use></svg></button>
    </div>
    <div class="card-body grid" style="gap:var(--space-4)">
      <p class="muted text-sm">Tax will be waived on this sale. A reason is required for the audit trail.</p>
      <div class="field">
        <label for="taxfree-reason-input">Reason</label>
        <select class="select" id="taxfree-reason-input">
          <option>Resale (tax-exempt customer)</option>
          <option>Charitable organization</option>
          <option>Government / school</option>
          <option>Other (documented)</option>
        </select>
      </div>
    </div>
    <div class="card-foot row between">
      <button class="btn btn-ghost" type="button" id="taxfree-off">Restore tax</button>
      <button class="btn btn-primary" type="button" id="taxfree-apply">Waive tax</button>
    </div>
  </div>
</div>

<!-- Payment modal -->
<div class="modal" id="pay-modal" hidden>
  <div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="pay-title">
    <div class="card-head"><div class="h3" id="pay-title">Take payment</div>
      <button class="icon-btn" type="button" data-close-modal aria-label="Close"><svg aria-hidden="true"><use href="#i-x"></use></svg></button>
    </div>
    <div class="card-body">
      <div class="row between" style="padding:var(--space-3) var(--space-4); background:var(--surface-2); border-radius:var(--radius)">
        <span class="muted">Balance due</span>
        <span class="h2 tnum" id="pay-balance">$0.00</span>
      </div>

      <div class="grid mt-4" style="gap:var(--space-3)">
        <div class="field">
          <label>Tender type</label>
          <div class="tender-grid" id="tender-grid">
            <?php foreach ($tenders as $t): ?>
              <button class="tender-btn" type="button" data-tender="<?= View::e($t['id']) ?>">
                <svg aria-hidden="true"><use href="#<?= View::e($t['icon']) ?>"></use></svg>
                <span><?= View::e($t['label']) ?></span>
              </button>
            <?php endforeach; ?>
          </div>
        </div>
        <div class="field">
          <label for="pay-amount-input">Amount</label>
          <input class="input" id="pay-amount-input" type="text" inputmode="decimal" placeholder="0.00">
        </div>
        <button class="btn btn-primary btn-block" type="button" id="pay-add">Add tender</button>
      </div>

      <div class="mt-4" id="tender-list"></div>
    </div>
    <div class="card-foot row between">
      <button class="btn btn-ghost" type="button" data-close-modal>Cancel</button>
      <button class="btn btn-primary" type="button" id="pay-complete" disabled>Complete sale</button>
    </div>
  </div>
</div>

<!-- Receipt modal -->
<div class="modal" id="receipt-modal" hidden>
  <div class="modal-panel" role="dialog" aria-modal="true" aria-labelledby="receipt-title">
    <div class="card-head"><div class="h3" id="receipt-title">Sale complete</div></div>
    <div class="card-body" id="receipt-body"></div>
    <div class="card-foot row between">
      <button class="btn" type="button" id="receipt-print"><svg aria-hidden="true"><use href="#i-receipt"></use></svg> Print</button>
      <button class="btn btn-primary" type="button" id="receipt-new">New sale</button>
    </div>
  </div>
</div>
