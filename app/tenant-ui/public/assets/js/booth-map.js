/* ==========================================================================
   Ninja EMP — 2D booth map island
   Click/keyboard-select a booth to show details in the side panel.
   ========================================================================== */
(function () {
  'use strict';

  var map = document.getElementById('booth-map');
  if (!map) return;

  var empty = document.getElementById('booth-detail-empty');
  var body = document.getElementById('booth-detail-body');
  var codeEl = document.getElementById('bd-code');
  var statusEl = document.getElementById('bd-status');
  var vendorEl = document.getElementById('bd-vendor');
  var rentEl = document.getElementById('bd-rent');
  var editEl = document.getElementById('bd-edit');

  var badgeClass = {
    leased: 'badge-success', available: 'badge-info', reserved: 'badge-accent',
    maintenance: 'badge-warning', inactive: ''
  };

  function select(cell) {
    document.querySelectorAll('.booth-cell').forEach(function (c) {
      c.classList.toggle('is-selected', c === cell);
    });
    empty.hidden = true;
    body.hidden = false;
    codeEl.textContent = cell.getAttribute('data-code');
    var status = cell.getAttribute('data-status');
    statusEl.innerHTML = '';
    var badge = document.createElement('span');
    badge.className = 'badge badge-dot ' + (badgeClass[status] || '');
    badge.textContent = status.charAt(0).toUpperCase() + status.slice(1);
    statusEl.appendChild(badge);
    vendorEl.textContent = cell.getAttribute('data-vendor');
    rentEl.textContent = cell.getAttribute('data-rent');
    editEl.setAttribute('href', '/booths/' + cell.getAttribute('data-booth'));
  }

  document.querySelectorAll('.booth-cell').forEach(function (cell) {
    cell.addEventListener('click', function (e) {
      // First click selects; second click (or Enter) navigates.
      if (!cell.classList.contains('is-selected')) {
        e.preventDefault();
        select(cell);
      }
    });
    cell.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' && !cell.classList.contains('is-selected')) {
        e.preventDefault();
        select(cell);
      }
    });
  });
})();
