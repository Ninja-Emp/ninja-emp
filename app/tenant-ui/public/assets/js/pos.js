/* ==========================================================================
   Ninja EMP — POS island
   Cart, barcode scan, split payments, hold/resume, discounts, tax-free.
   Money is handled in integer cents to avoid float drift; formatted at render.
   ========================================================================== */
(function () {
  'use strict';

  var root = document.getElementById('pos');
  if (!root) return;

  var CURRENCY = root.getAttribute('data-currency') || 'USD';
  var TAX_RATE = parseFloat(root.getAttribute('data-tax-rate') || '0'); // percent

  var state = {
    lines: [],          // {id,name,sku,price(cents),qty,vendor}
    discount: null,     // {type:'percent'|'amount', value, reason}
    taxFree: false,
    taxFreeReason: '',
    tenders: [],        // {type, amount(cents)}
    held: []            // {id,label,lines,discount,taxFree,taxFreeReason}
  };

  /* ---- Money helpers (integer cents) ----------------------------------- */
  function toCents(str) {
    var n = parseFloat(String(str).replace(/[^0-9.\-]/g, ''));
    if (isNaN(n)) return 0;
    return Math.round(n * 100);
  }
  function fmt(cents) {
    var neg = cents < 0;
    cents = Math.abs(cents);
    var whole = Math.floor(cents / 100).toLocaleString('en-US');
    var frac = String(cents % 100).padStart(2, '0');
    var sym = CURRENCY === 'USD' ? '$' : (CURRENCY === 'EUR' ? '\u20AC' : (CURRENCY === 'GBP' ? '\u00A3' : CURRENCY + ' '));
    return (neg ? '-' : '') + sym + whole + '.' + frac;
  }

  /* ---- Totals ----------------------------------------------------------- */
  function subtotal() {
    return state.lines.reduce(function (s, l) { return s + l.price * l.qty; }, 0);
  }
  function discountAmount() {
    var sub = subtotal();
    if (!state.discount) return 0;
    if (state.discount.type === 'percent') {
      return Math.round(sub * (state.discount.value / 100));
    }
    return Math.min(toCents(state.discount.value), sub);
  }
  function taxableBase() {
    return Math.max(0, subtotal() - discountAmount());
  }
  function taxAmount() {
    if (state.taxFree) return 0;
    return Math.round(taxableBase() * (TAX_RATE / 100));
  }
  function total() {
    return taxableBase() + taxAmount();
  }
  function tenderedTotal() {
    return state.tenders.reduce(function (s, t) { return s + t.amount; }, 0);
  }
  function balanceDue() {
    return Math.max(0, total() - tenderedTotal());
  }

  /* ---- Render cart ------------------------------------------------------ */
  var cartLines = document.getElementById('cart-lines');
  var cartEmpty = document.getElementById('cart-empty');

  function renderCart() {
    cartLines.querySelectorAll('.pos-line').forEach(function (n) { n.remove(); });
    cartEmpty.hidden = state.lines.length > 0;

    state.lines.forEach(function (l) {
      var el = document.createElement('div');
      el.className = 'pos-line';
      el.innerHTML =
        '<div>' +
          '<div class="pos-line-name"></div>' +
          '<div class="pos-line-sub mono"></div>' +
        '</div>' +
        '<div class="pos-line-right">' +
          '<span class="strong tnum"></span>' +
          '<div class="qty">' +
            '<button type="button" data-dec aria-label="Decrease">\u2212</button>' +
            '<span></span>' +
            '<button type="button" data-inc aria-label="Increase">+</button>' +
          '</div>' +
        '</div>';
      el.querySelector('.pos-line-name').textContent = l.name;
      el.querySelector('.pos-line-sub').textContent = l.sku;
      el.querySelector('.pos-line-right .strong').textContent = fmt(l.price * l.qty);
      el.querySelector('.qty span').textContent = l.qty;
      el.querySelector('[data-inc]').addEventListener('click', function () { changeQty(l.id, 1); });
      el.querySelector('[data-dec]').addEventListener('click', function () { changeQty(l.id, -1); });
      cartLines.appendChild(el);
    });

    renderTotals();
  }

  function renderTotals() {
    document.getElementById('t-subtotal').textContent = fmt(subtotal());
    var d = discountAmount();
    var rowD = document.getElementById('row-discount');
    rowD.hidden = d <= 0;
    if (d > 0) {
      document.getElementById('t-discount').textContent = '-' + fmt(d);
      document.getElementById('discount-label').textContent =
        state.discount.type === 'percent' ? '(' + state.discount.value + '% · ' + state.discount.reason + ')'
                                          : '(' + state.discount.reason + ')';
    }
    document.getElementById('t-tax').textContent = fmt(taxAmount());
    document.getElementById('row-tax').hidden = state.taxFree;
    document.getElementById('row-taxfree').hidden = !state.taxFree;
    if (state.taxFree) document.getElementById('taxfree-reason').textContent = state.taxFreeReason;
    document.getElementById('t-total').textContent = fmt(total());
    document.getElementById('pay-amount').textContent = fmt(total());
    document.getElementById('btn-pay').disabled = state.lines.length === 0;
  }

  /* ---- Cart mutations --------------------------------------------------- */
  function addItem(item) {
    var existing = state.lines.find(function (l) { return l.id === item.id; });
    if (existing) { existing.qty += 1; }
    else {
      state.lines.push({
        id: item.id, name: item.name, sku: item.sku,
        price: toCents(item.price), qty: 1, vendor: item.vendor
      });
    }
    renderCart();
  }
  function changeQty(id, delta) {
    var l = state.lines.find(function (x) { return x.id === id; });
    if (!l) return;
    l.qty += delta;
    if (l.qty <= 0) state.lines = state.lines.filter(function (x) { return x.id !== id; });
    renderCart();
  }

  /* ---- Catalog tiles ---------------------------------------------------- */
  document.querySelectorAll('[data-add-item]').forEach(function (tile) {
    tile.addEventListener('click', function () {
      addItem({
        id: tile.getAttribute('data-id'),
        name: tile.getAttribute('data-name'),
        sku: tile.getAttribute('data-sku'),
        price: tile.getAttribute('data-price'),
        vendor: tile.getAttribute('data-vendor')
      });
    });
  });

  /* ---- Catalog filter --------------------------------------------------- */
  var catSearch = document.getElementById('catalog-search');
  catSearch.addEventListener('input', function () {
    var q = catSearch.value.toLowerCase();
    document.querySelectorAll('[data-add-item]').forEach(function (tile) {
      tile.style.display = tile.getAttribute('data-search').indexOf(q) !== -1 ? '' : 'none';
    });
  });

  /* ---- Barcode scan ----------------------------------------------------- */
  var scanInput = document.getElementById('scan');
  var scanMsg = document.getElementById('scan-msg');

  function doScan() {
    var code = scanInput.value.trim();
    if (!code) return;
    scanMsg.textContent = 'Looking up…';
    fetch('/pos/scan', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'code=' + encodeURIComponent(code)
    })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        if (data.ok) {
          addItem({
            id: data.item.id, name: data.item.name, sku: data.item.sku,
            price: data.item.price, vendor: data.item.vendor_id
          });
          scanMsg.textContent = 'Added: ' + data.item.name;
          scanMsg.style.color = 'var(--success)';
        } else {
          scanMsg.textContent = data.error || 'Not found.';
          scanMsg.style.color = 'var(--danger)';
        }
        scanInput.value = '';
        scanInput.focus();
      })
      .catch(function () {
        scanMsg.textContent = 'Lookup failed.';
        scanMsg.style.color = 'var(--danger)';
      });
  }
  scanInput.addEventListener('keydown', function (e) { if (e.key === 'Enter') { e.preventDefault(); doScan(); } });
  document.getElementById('scan-btn').addEventListener('click', doScan);

  /* ---- Clear ------------------------------------------------------------ */
  document.getElementById('clear-cart').addEventListener('click', function () {
    state.lines = []; state.discount = null; state.taxFree = false; state.tenders = [];
    renderCart();
  });

  /* ---- Modals ----------------------------------------------------------- */
  function openModal(id) { document.getElementById(id).hidden = false; }
  function closeModal(id) { document.getElementById(id).hidden = true; }
  document.querySelectorAll('[data-close-modal]').forEach(function (b) {
    b.addEventListener('click', function () { b.closest('.modal').hidden = true; });
  });
  document.querySelectorAll('.modal').forEach(function (m) {
    m.addEventListener('click', function (e) { if (e.target === m) m.hidden = true; });
  });

  /* ---- Discount --------------------------------------------------------- */
  var discountType = 'percent';
  document.querySelectorAll('[data-dtype]').forEach(function (b) {
    b.addEventListener('click', function () {
      discountType = b.getAttribute('data-dtype');
      document.querySelectorAll('[data-dtype]').forEach(function (x) {
        x.setAttribute('aria-pressed', x === b ? 'true' : 'false');
      });
    });
  });
  document.getElementById('btn-discount').addEventListener('click', function () {
    if (state.discount) {
      document.getElementById('discount-value').value = state.discount.value;
      document.getElementById('discount-reason').value = state.discount.reason;
    }
    openModal('discount-modal');
  });
  document.getElementById('discount-apply').addEventListener('click', function () {
    var val = parseFloat(document.getElementById('discount-value').value);
    if (isNaN(val) || val <= 0) return;
    state.discount = {
      type: discountType, value: val,
      reason: document.getElementById('discount-reason').value
    };
    closeModal('discount-modal');
    renderTotals();
  });
  document.getElementById('discount-remove').addEventListener('click', function () {
    state.discount = null; closeModal('discount-modal'); renderTotals();
  });

  /* ---- Tax-free --------------------------------------------------------- */
  document.getElementById('btn-taxfree').addEventListener('click', function () { openModal('taxfree-modal'); });
  document.getElementById('taxfree-apply').addEventListener('click', function () {
    state.taxFree = true;
    state.taxFreeReason = document.getElementById('taxfree-reason-input').value;
    closeModal('taxfree-modal'); renderTotals();
  });
  document.getElementById('taxfree-off').addEventListener('click', function () {
    state.taxFree = false; state.taxFreeReason = ''; closeModal('taxfree-modal'); renderTotals();
  });

  /* ---- Hold / resume ---------------------------------------------------- */
  var heldCard = document.getElementById('held-card');
  var heldList = document.getElementById('held-list');

  function renderHeld() {
    heldCard.hidden = state.held.length === 0;
    heldList.innerHTML = '';
    state.held.forEach(function (h) {
      var row = document.createElement('div');
      row.className = 'tender-row';
      row.innerHTML = '<span><span class="strong"></span><br><span class="text-xs subtle"></span></span>' +
                      '<button class="btn btn-sm" type="button">Resume</button>';
      row.querySelector('.strong').textContent = h.label;
      row.querySelector('.text-xs').textContent = h.lines.length + ' item(s) · ' + fmt(h.total);
      row.querySelector('button').addEventListener('click', function () {
        state.lines = h.lines; state.discount = h.discount;
        state.taxFree = h.taxFree; state.taxFreeReason = h.taxFreeReason;
        state.held = state.held.filter(function (x) { return x.id !== h.id; });
        renderCart(); renderHeld();
      });
      heldList.appendChild(row);
    });
  }
  document.getElementById('btn-hold').addEventListener('click', function () {
    if (state.lines.length === 0) return;
    state.held.push({
      id: 'h-' + Date.now(),
      label: 'Held ' + new Date().toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' }),
      lines: state.lines.slice(), discount: state.discount,
      taxFree: state.taxFree, taxFreeReason: state.taxFreeReason, total: total()
    });
    state.lines = []; state.discount = null; state.taxFree = false; state.tenders = [];
    renderCart(); renderHeld();
  });

  /* ---- Payment ---------------------------------------------------------- */
  var selectedTender = null;
  document.querySelectorAll('[data-tender]').forEach(function (b) {
    b.addEventListener('click', function () {
      selectedTender = b.getAttribute('data-tender');
      document.querySelectorAll('[data-tender]').forEach(function (x) {
        x.setAttribute('aria-pressed', x === b ? 'true' : 'false');
      });
      var amt = document.getElementById('pay-amount-input');
      if (!amt.value) amt.value = (balanceDue() / 100).toFixed(2);
    });
  });

  function renderTenders() {
    var list = document.getElementById('tender-list');
    list.innerHTML = '';
    state.tenders.forEach(function (t, i) {
      var row = document.createElement('div');
      row.className = 'tender-row';
      row.innerHTML = '<span class="strong"></span><span class="row gap-3"><span class="tnum"></span>' +
                      '<button class="rm" type="button" aria-label="Remove">\u2715</button></span>';
      row.querySelector('.strong').textContent = t.label;
      row.querySelector('.tnum').textContent = fmt(t.amount);
      row.querySelector('.rm').addEventListener('click', function () {
        state.tenders.splice(i, 1); renderTenders(); updatePay();
      });
      list.appendChild(row);
    });
  }
  function updatePay() {
    document.getElementById('pay-balance').textContent = fmt(balanceDue());
    document.getElementById('pay-complete').disabled = balanceDue() > 0 || state.lines.length === 0;
  }
  document.getElementById('btn-pay').addEventListener('click', function () {
    state.tenders = [];
    document.getElementById('pay-amount-input').value = (total() / 100).toFixed(2);
    renderTenders(); updatePay(); openModal('pay-modal');
  });
  document.getElementById('pay-add').addEventListener('click', function () {
    if (!selectedTender) { alert('Choose a tender type first.'); return; }
    var amt = toCents(document.getElementById('pay-amount-input').value);
    if (amt <= 0) return;
    var label = document.querySelector('[data-tender="' + selectedTender + '"] span').textContent;
    state.tenders.push({ type: selectedTender, label: label, amount: amt });
    document.getElementById('pay-amount-input').value = (balanceDue() / 100).toFixed(2);
    renderTenders(); updatePay();
  });

  document.getElementById('pay-complete').addEventListener('click', function () {
    fetch('/pos/checkout', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: 'total=' + encodeURIComponent((total() / 100).toFixed(2))
    })
      .then(function (r) { return r.json(); })
      .then(function (data) {
        closeModal('pay-modal');
        showReceipt(data.receipt || 'S-0000');
      })
      .catch(function () { closeModal('pay-modal'); showReceipt('S-0000'); });
  });

  function showReceipt(no) {
    var body = document.getElementById('receipt-body');
    body.innerHTML = '';
    var head = document.createElement('div');
    head.className = 'row between';
    head.innerHTML = '<span class="muted">Receipt</span><span class="mono strong"></span>';
    head.querySelector('.strong').textContent = no;
    body.appendChild(head);

    var list = document.createElement('div');
    list.className = 'mt-4';
    state.lines.forEach(function (l) {
      var r = document.createElement('div');
      r.className = 'row between';
      r.innerHTML = '<span></span><span class="tnum"></span>';
      r.querySelector('span').textContent = l.qty + ' × ' + l.name;
      r.querySelector('.tnum').textContent = fmt(l.price * l.qty);
      list.appendChild(r);
    });
    body.appendChild(list);

    var tot = document.createElement('div');
    tot.className = 'row between mt-4';
    tot.style.paddingTop = 'var(--space-3)';
    tot.style.borderTop = '1px dashed var(--border)';
    tot.innerHTML = '<span class="strong">Total</span><span class="h3 tnum"></span>';
    tot.querySelector('.tnum').textContent = fmt(total());
    body.appendChild(tot);

    openModal('receipt-modal');
  }
  document.getElementById('receipt-new').addEventListener('click', function () {
    state.lines = []; state.discount = null; state.taxFree = false; state.tenders = [];
    closeModal('receipt-modal'); renderCart(); scanInput.focus();
  });
  document.getElementById('receipt-print').addEventListener('click', function () { window.print(); });

  /* ---- Keyboard shortcuts ---------------------------------------------- */
  document.addEventListener('keydown', function (e) {
    if (e.key === 'F2') { e.preventDefault(); scanInput.focus(); }
    if (e.key === 'F4') { e.preventDefault(); if (state.lines.length) document.getElementById('btn-pay').click(); }
    if (e.key === 'F8') { e.preventDefault(); document.getElementById('btn-hold').click(); }
    if (e.key === 'Escape') {
      document.querySelectorAll('.modal').forEach(function (m) { m.hidden = true; });
    }
  });

  renderCart();
})();
