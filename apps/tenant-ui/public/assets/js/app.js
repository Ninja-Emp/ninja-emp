/* ==========================================================================
   Ninja EMP — Tenant UI shell behavior
   Sidebar collapse, mobile drawer, theme/mode switching, dropdown menus,
   global search shortcut. No dependencies.
   ========================================================================== */
(function () {
  'use strict';

  var app = document.getElementById('app');
  var root = document.documentElement;

  /* ---- Sidebar collapse (persisted) ------------------------------------ */
  var COLLAPSE_KEY = 'nem-sidebar-collapsed';
  try {
    if (localStorage.getItem(COLLAPSE_KEY) === '1') {
      app.setAttribute('data-collapsed', 'true');
    }
  } catch (e) {}

  document.querySelectorAll('[data-collapse-toggle]').forEach(function (btn) {
    btn.addEventListener('click', function () {
      var collapsed = app.getAttribute('data-collapsed') === 'true';
      app.setAttribute('data-collapsed', collapsed ? 'false' : 'true');
      try { localStorage.setItem(COLLAPSE_KEY, collapsed ? '0' : '1'); } catch (e) {}
    });
  });

  /* ---- Mobile drawer ---------------------------------------------------- */
  document.querySelectorAll('[data-mobile-toggle]').forEach(function (el) {
    el.addEventListener('click', function () {
      var open = app.getAttribute('data-mobile-open') === 'true';
      app.setAttribute('data-mobile-open', open ? 'false' : 'true');
    });
  });

  /* ---- Theme + mode ----------------------------------------------------- */
  function setTheme(theme) {
    root.setAttribute('data-theme', theme);
    try { localStorage.setItem('nem-theme', theme); } catch (e) {}
    document.querySelectorAll('[data-set-theme]').forEach(function (b) {
      b.setAttribute('aria-checked', b.getAttribute('data-set-theme') === theme ? 'true' : 'false');
    });
  }
  function setMode(mode) {
    root.setAttribute('data-mode', mode);
    try { localStorage.setItem('nem-mode', mode); } catch (e) {}
    document.querySelectorAll('[data-set-mode]').forEach(function (b) {
      b.setAttribute('aria-checked', b.getAttribute('data-set-mode') === mode ? 'true' : 'false');
    });
  }
  document.querySelectorAll('[data-set-theme]').forEach(function (b) {
    b.addEventListener('click', function () { setTheme(b.getAttribute('data-set-theme')); });
  });
  document.querySelectorAll('[data-set-mode]').forEach(function (b) {
    b.addEventListener('click', function () { setMode(b.getAttribute('data-set-mode')); });
  });

  /* ---- Dropdown menus --------------------------------------------------- */
  function closeAllMenus(except) {
    document.querySelectorAll('[data-menu]').forEach(function (menu) {
      if (menu === except) return;
      var panel = menu.querySelector('[data-menu-panel]');
      var trigger = menu.querySelector('[data-menu-trigger]');
      if (panel) panel.hidden = true;
      if (trigger) trigger.setAttribute('aria-expanded', 'false');
    });
  }
  document.querySelectorAll('[data-menu]').forEach(function (menu) {
    var trigger = menu.querySelector('[data-menu-trigger]');
    var panel = menu.querySelector('[data-menu-panel]');
    if (!trigger || !panel) return;
    trigger.addEventListener('click', function (e) {
      e.stopPropagation();
      var willOpen = panel.hidden;
      closeAllMenus(menu);
      panel.hidden = !willOpen;
      trigger.setAttribute('aria-expanded', willOpen ? 'true' : 'false');
    });
  });
  document.addEventListener('click', function () { closeAllMenus(null); });
  document.addEventListener('keydown', function (e) {
    if (e.key === 'Escape') closeAllMenus(null);
  });

  /* ---- Global search shortcut ("/") ------------------------------------ */
  var search = document.querySelector('[data-global-search]');
  document.addEventListener('keydown', function (e) {
    if (e.key === '/' && document.activeElement !== search &&
        !/^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement.tagName)) {
      e.preventDefault();
      if (search) search.focus();
    }
  });
})();
