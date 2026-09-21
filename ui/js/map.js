/* ============================================================================
   Ninja EMP — Mall Floor Plan "map island"
   A single, self-contained interactive island. Click (or keyboard-activate)
   a booth to see its friendly details. No framework, no build step.
   ============================================================================ */
(function () {
  'use strict';

  // Booth data — in the real app this comes from the `space` table
  // (space_type_code, area_sqft, status) via the vendor portal API.
  var BOOTHS = {
    'A-12': { name: 'Your Booth', status: 'yours',   type: 'Inline booth', sqft: 120, note: 'This is your space. It is all set up and ready for shoppers.' },
    'A-11': { name: 'Booth A-11', status: 'leased',  type: 'Inline booth', sqft: 110, note: 'Leased by The Quilt Corner.' },
    'A-13': { name: 'Booth A-13', status: 'leased',  type: 'Inline booth', sqft: 110, note: 'Leased by Grandma\u2019s Jams & Jellies.' },
    'A-14': { name: 'Booth A-14', status: 'available', type: 'Inline booth', sqft: 110, note: 'Open right now \u2014 ask the office if you would like to grow.' },
    'B-01': { name: 'Booth B-01', status: 'leased',  type: 'Endcap',       sqft: 80,  note: 'Leased by Handmade Soaps by Dee.' },
    'B-02': { name: 'Booth B-02', status: 'available', type: 'Endcap',     sqft: 80,  note: 'Open right now.' },
    'B-03': { name: 'Booth B-03', status: 'maintenance', type: 'Endcap',   sqft: 80,  note: 'Getting a fresh coat of paint this week.' },
    'K-1':  { name: 'Kiosk K-1',  status: 'leased',  type: 'Kiosk',        sqft: 40,  note: 'Leased by Sweet Treats Bakery.' },
    'K-2':  { name: 'Kiosk K-2',  status: 'available', type: 'Kiosk',      sqft: 40,  note: 'Open right now.' },
    'C-1':  { name: 'Cart C-1',   status: 'leased',  type: 'Cart',         sqft: 24,  note: 'Leased by Kettle Corn Cart.' }
  };

  var COLORS = {
    yours:       { fill: '#F2A93B', stroke: '#B45309' },
    leased:      { fill: '#E3F2EE', stroke: '#0E6E5C' },
    available:   { fill: '#FFFFFF', stroke: '#8A7866' },
    maintenance: { fill: '#FBE7E9', stroke: '#B23A48' }
  };

  var detail = document.getElementById('map-detail');
  var svg = document.getElementById('floorplan');
  if (!svg) return;

  function showBooth(id) {
    var b = BOOTHS[id];
    if (!b || !detail) return;

    // Highlight the selected booth
    svg.querySelectorAll('.booth').forEach(function (g) {
      g.classList.toggle('selected', g.getAttribute('data-booth') === id);
    });

    var statusPill = {
      yours:       '<span class="pill pill-warn">\u2b50 This is yours</span>',
      leased:      '<span class="pill pill-brand">Leased</span>',
      available:   '<span class="pill pill-good">Available</span>',
      maintenance: '<span class="pill pill-rose">Being fixed up</span>'
    }[b.status];

    detail.innerHTML =
      '<h3>' + b.name + ' &nbsp;' + statusPill + '</h3>' +
      '<p class="lead mb-0">' + b.note + '</p>' +
      '<p class="muted mt-2 mb-0">' +
        '<strong>Type:</strong> ' + b.type + ' &nbsp;&middot;&nbsp; ' +
        '<strong>Size:</strong> about ' + b.sqft + ' square feet' +
      '</p>';

    if (window.ninjaAnnounce) window.ninjaAnnounce(b.name + '. ' + b.note);
  }

  // Wire up every booth for mouse and keyboard.
  svg.querySelectorAll('.booth').forEach(function (g) {
    var id = g.getAttribute('data-booth');
    g.setAttribute('tabindex', '0');
    g.setAttribute('role', 'button');
    g.setAttribute('aria-label', (BOOTHS[id] ? BOOTHS[id].name : id) + ' \u2014 press to see details');
    g.addEventListener('click', function () { showBooth(id); });
    g.addEventListener('keydown', function (e) {
      if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); showBooth(id); }
    });
  });

  // Start with the vendor's own booth selected.
  showBooth('A-12');
})();
