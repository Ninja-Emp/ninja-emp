/* ============================================================================
   Ninja EMP — Grandma-Friendly Vendor Portal
   app.js — shared, dependency-free progressive enhancement.
   Everything here is optional: the pages work fully without JavaScript.
   ============================================================================ */
(function () {
  'use strict';

  /* ---- 1. Bigger Text toggle ---------------------------------------------
     Remembers the choice in localStorage so it sticks between pages. */
  var root = document.documentElement;
  var bigBtn = document.getElementById('btn-bigger-text');

  function applyTextSize(large) {
    root.classList.toggle('text-large', large);
    if (bigBtn) bigBtn.setAttribute('aria-pressed', large ? 'true' : 'false');
  }

  var savedLarge = false;
  try { savedLarge = localStorage.getItem('ninjaemp.bigtext') === '1'; } catch (e) {}
  applyTextSize(savedLarge);

  if (bigBtn) {
    bigBtn.addEventListener('click', function () {
      var next = !root.classList.contains('text-large');
      applyTextSize(next);
      try { localStorage.setItem('ninjaemp.bigtext', next ? '1' : '0'); } catch (e) {}
      announce(next ? 'Text is now bigger.' : 'Text is back to normal size.');
    });
  }

  /* ---- 2. Read Aloud toggle ----------------------------------------------
     Uses the browser's built-in speech synthesis. Reads the main content
     in plain language. A second press stops it. */
  var readBtn = document.getElementById('btn-read-aloud');
  var speaking = false;

  function stopSpeaking() {
    if ('speechSynthesis' in window) window.speechSynthesis.cancel();
    speaking = false;
    if (readBtn) {
      readBtn.setAttribute('aria-pressed', 'false');
      readBtn.querySelector('.label').textContent = 'Read This Page';
    }
  }

  function startSpeaking() {
    if (!('speechSynthesis' in window)) {
      announce('Sorry, reading aloud is not available on this device.');
      return;
    }
    var main = document.getElementById('main') || document.body;
    // Read the visible text, skipping the navigation and buttons.
    var text = main.innerText.replace(/\s+/g, ' ').trim();
    var utter = new SpeechSynthesisUtterance(text);
    utter.rate = 0.92;   // a touch slower — easier to follow
    utter.pitch = 1.0;
    utter.onend = stopSpeaking;
    window.speechSynthesis.cancel();
    window.speechSynthesis.speak(utter);
    speaking = true;
    if (readBtn) {
      readBtn.setAttribute('aria-pressed', 'true');
      readBtn.querySelector('.label').textContent = 'Stop Reading';
    }
  }

  if (readBtn) {
    readBtn.addEventListener('click', function () {
      if (speaking) { stopSpeaking(); } else { startSpeaking(); }
    });
    // Stop reading if the user leaves the page.
    window.addEventListener('beforeunload', stopSpeaking);
  }

  /* ---- 3. Polite screen-reader announcements ----------------------------- */
  var live = document.getElementById('live-region');
  function announce(msg) {
    if (!live) return;
    live.textContent = '';
    // A tiny delay makes some screen readers pick up the change reliably.
    setTimeout(function () { live.textContent = msg; }, 60);
  }
  window.ninjaAnnounce = announce;

  /* ---- 4. Friendly "money" formatting helper -----------------------------
     Kept here so every page shows dollars the same, friendly way. */
  window.ninjaMoney = function (n) {
    var v = Number(n) || 0;
    return '$' + v.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  };

  /* ---- 5. Mark the current page in the nav ------------------------------- */
  var here = location.pathname.split('/').pop() || 'index.html';
  document.querySelectorAll('.mainnav a').forEach(function (a) {
    var target = a.getAttribute('href');
    if (target === here) a.setAttribute('aria-current', 'page');
  });
})();
