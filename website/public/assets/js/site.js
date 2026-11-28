// TidyByte marketing site — UI enhancements layered on top of nav.js.
// Pure vanilla JS, no dependencies. Safe to defer-load.

(function () {
  'use strict';

  function prefersReduced() {
    return Boolean(window.matchMedia &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches);
  }

  document.addEventListener('DOMContentLoaded', function () {
    initThemeToggle();
    initReveal();
    initImageFade();
    initIosDemo();
    initMacDemo();
    initDesktopDemo();
    initBentoTidy();
    initKeyboardExplorer();
    initMobileCarousels();
    initPlanSwitcher();
  });

  // 1) Light / Dark / System popover in the header.
  function initThemeToggle() {
    var btn = document.querySelector('[data-theme-toggle]');
    var menu = document.querySelector('[data-theme-menu]');
    if (!btn || !menu || !window.__tidybyteTheme) return;

    var closing = false;
    var closeTimer = null;
    var themeFadeTimer = null;
    var tabbing = false;
    var tabTimer = null;

    function isOpen() {
      return btn.getAttribute('aria-expanded') === 'true';
    }

    function getOptions() {
      return Array.prototype.slice.call(menu.querySelectorAll('[data-theme-option]'));
    }

    function finishThemeFade() {
      window.clearTimeout(themeFadeTimer);
      themeFadeTimer = null;
      document.documentElement.classList.remove('theme-switching');
    }

    document.body.addEventListener('transitionend', function (event) {
      if (event.target === document.body && event.propertyName === 'background-color') finishThemeFade();
    });

    function sync() {
      var current = window.__tidybyteTheme.get();
      var options = getOptions();
      for (var i = 0; i < options.length; i++) {
        var opt = options[i];
        var active = opt.getAttribute('data-theme-option') === current;
        opt.setAttribute('aria-checked', String(active));
        var dot = opt.querySelector('[data-theme-dot]');
        if (dot) dot.classList.toggle('opacity-0', !active);
      }
    }

    // The close animation needs the node to stay rendered, so `hidden` lands a
    // beat after `.is-closing`. aria-expanded still flips immediately — the
    // popover is already dismissed as far as the accessibility tree cares.
    function finishClose() {
      window.clearTimeout(closeTimer);
      closeTimer = null;
      closing = false;
      menu.classList.remove('is-closing');
      menu.classList.add('hidden');
    }

    function setOpen(open) {
      btn.setAttribute('aria-expanded', String(open));

      if (open) {
        window.clearTimeout(closeTimer);
        closeTimer = null;
        closing = false;
        menu.classList.remove('is-closing');
        menu.classList.remove('hidden');
        sync();
        return;
      }

      if (closing) return;
      if (menu.classList.contains('hidden')) return;
      if (prefersReduced()) { finishClose(); return; }

      closing = true;
      menu.classList.add('is-closing');
      // Fallback if the animation is interrupted or unavailable.
      closeTimer = window.setTimeout(finishClose, 250);
    }

    menu.addEventListener('animationend', function (event) {
      if (closing && event.target === menu && event.animationName === 'pop-out') finishClose();
    });

    btn.addEventListener('click', function () {
      setOpen(!isOpen());
    });

    menu.addEventListener('click', function (event) {
      var opt = event.target.closest('[data-theme-option]');
      if (!opt) return;
      // Crossfade the palette instead of hard-cutting every surface.
      if (!prefersReduced()) {
        document.documentElement.classList.add('theme-switching');
        window.clearTimeout(themeFadeTimer);
        // Fallback when the selected theme does not change the background.
        themeFadeTimer = window.setTimeout(finishThemeFade, 300);
      }
      window.__tidybyteTheme.set(opt.getAttribute('data-theme-option'));
      sync();
      setOpen(false);
      btn.focus();
    });

    // Close on outside click.
    document.addEventListener('click', function (event) {
      if (!isOpen()) return;
      if (menu.contains(event.target) || btn.contains(event.target)) return;
      setOpen(false);
    });

    // Close when focus leaves both the toggle button and menu (e.g. Tab out).
    function handleFocusOut(event) {
      if (!isOpen()) return;
      var next = event.relatedTarget;
      if (next && (menu.contains(next) || btn.contains(next))) return;
      if (next || tabbing) setOpen(false);
    }
    btn.addEventListener('focusout', handleFocusOut);
    menu.addEventListener('focusout', handleFocusOut);

    document.addEventListener('focusin', function (event) {
      if (!isOpen()) return;
      if (menu.contains(event.target) || btn.contains(event.target)) return;
      setOpen(false);
    });

    // WAI-ARIA keyboard navigation: Escape, ArrowDown/Up, Home/End, and Tab out.
    document.addEventListener('keydown', function (event) {
      if (!isOpen()) return;

      if (event.key === 'Escape') {
        setOpen(false);
        btn.focus();
        return;
      }

      if (event.key === 'Tab') {
        tabbing = true;
        window.clearTimeout(tabTimer);
        tabTimer = window.setTimeout(function () {
          tabbing = false;
          tabTimer = null;
        }, 0);
        return;
      }

      var key = event.key;
      if (key !== 'ArrowDown' && key !== 'ArrowUp' && key !== 'Home' && key !== 'End') return;

      var inWidget = menu.contains(event.target) || btn.contains(event.target) ||
        menu.contains(document.activeElement) || document.activeElement === btn;
      if (!inWidget) return;

      var options = getOptions();
      if (!options.length) return;

      var idx = options.indexOf(document.activeElement);
      if (idx === -1 && event.target && event.target.closest) {
        var targetOpt = event.target.closest('[data-theme-option]');
        if (targetOpt) idx = options.indexOf(targetOpt);
      }

      var nextIdx;
      if (key === 'Home') {
        nextIdx = 0;
      } else if (key === 'End') {
        nextIdx = options.length - 1;
      } else if (key === 'ArrowDown') {
        nextIdx = idx === -1 ? 0 : (idx + 1) % options.length;
      } else {
        nextIdx = idx === -1 ? options.length - 1 : (idx - 1 + options.length) % options.length;
      }

      event.preventDefault();
      options[nextIdx].focus();
    });

    sync();
  }

  // 2) Scroll-in reveals. Opt-in per element via [data-reveal]; skipped
  // entirely for visitors who prefer reduced motion.
  function initReveal() {
    var els = document.querySelectorAll('[data-reveal]');
    if (!els.length) return;

    var reduced = prefersReduced();

    if (reduced || !('IntersectionObserver' in window)) {
      for (var i = 0; i < els.length; i++) els[i].classList.add('is-revealed');
      document.documentElement.classList.add('reveal-ready');
      return;
    }

    // Elements sharing a group cascade in reading order so the eye can follow
    // the order they are meant to be read in. The cap keeps a twelve-card grid
    // from trickling in, and the small jitter stops the rhythm reading as a
    // metronome.
    var groups = document.querySelectorAll('[data-reveal-group]');
    for (var g = 0; g < groups.length; g++) {
      var children = groups[g].children;
      for (var c = 0, order = 0; c < children.length; c++) {
        if (!children[c].hasAttribute('data-reveal')) continue;
        var delay = Math.min(order, 7) * 40 + (order % 3) * 8;
        children[c].style.setProperty('--reveal-delay', delay + 'ms');
        order++;
      }
    }

    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        entry.target.classList.add('is-revealed');
        observer.unobserve(entry.target);
      });
    }, { threshold: 0.12, rootMargin: '0px 0px -8% 0px' });

    for (var j = 0; j < els.length; j++) observer.observe(els[j]);
    document.documentElement.classList.add('reveal-ready');
  }

  // 3) Lazy images fade in as they decode instead of popping in mid-scroll.
  // Nothing is hidden unless this function decided to hide it and has a load
  // handler attached, and a failed image is revealed rather than stranded.
  // `motion-fade` is swapped for `is-loaded` in the same frame; the animation
  // then settles on the image's own opacity, so `opacity-90` survives.
  function initImageFade() {
    var imgs = document.querySelectorAll('img[loading="lazy"]');
    for (var i = 0; i < imgs.length; i++) {
      (function (img) {
        if (img.complete && img.naturalWidth > 0) return;
        var reveal = function () {
          img.classList.remove('motion-fade');
          img.classList.add('is-loaded');
        };
        img.classList.add('motion-fade');
        img.addEventListener('load', reveal, { once: true });
        img.addEventListener('error', reveal, { once: true });
        if (img.complete) reveal();
      })(imgs[i]);
    }
  }

  // 4) Interactive iPhone demo: playable swipe deck + settings controls.
  // Pure progressive enhancement — Card 0 and default controls work with no JS.
  function initIosDemo() {
    var deck = document.querySelector('[data-ios-deck]');
    if (deck) {
      var cards = Array.prototype.slice.call(deck.querySelectorAll('[data-deck-card]'));
      var btnDel = document.querySelector('[data-deck-action="delete"]');
      var btnSkip = document.querySelector('[data-deck-action="skip"]');
      var btnKeep = document.querySelector('[data-deck-action="keep"]');
      var btnUndo = document.querySelector('[data-deck-undo]');
      var progressEl = document.querySelector('[data-deck-progress]');
      var counterEl = document.querySelector('[data-deck-counter]');
      var liveEl = document.querySelector('[data-deck-live]');
      var actionButtons = {
        'delete': btnDel,
        skip: btnSkip,
        keep: btnKeep
      };
      var current = 0;
      var history = [];
      var busy = false;
      var exitTimer = null;
      var pendingSwipe = null;

      function clearExitTimer() {
        if (exitTimer !== null) {
          window.clearTimeout(exitTimer);
          exitTimer = null;
        }
      }

      function updateCounter() {
        if (!counterEl || !cards.length) return;
        var currentText = String(current + 1);
        var fullText = currentText + ' / ' + cards.length;
        var explicitCurrent = counterEl.querySelector('[data-deck-current]');
        if (explicitCurrent) {
          explicitCurrent.textContent = currentText;
          return;
        }
        var spans = counterEl.querySelectorAll('span');
        for (var i = 0; i < spans.length; i++) {
          if (/^\d+$/.test(spans[i].textContent.trim())) {
            spans[i].textContent = currentText;
            return;
          }
        }
        if (spans.length === 1 && spans[0].textContent.indexOf('/') !== -1) {
          spans[0].textContent = fullText;
        } else if (spans.length && spans[0].textContent.indexOf('/') === -1) {
          spans[0].textContent = currentText;
        } else {
          counterEl.textContent = fullText;
        }
      }

      function announceDeck(actionBtn, card, index) {
        if (!liveEl) return;
        var parts = [];
        var actionLabel = actionBtn ? (actionBtn.getAttribute('aria-label') || '') : '';
        var cardLabel = card ? (card.getAttribute('aria-label') || '') : '';
        if (actionLabel) parts.push(actionLabel);
        if (cardLabel) parts.push(cardLabel);
        if (cards.length) {
          parts.push(((typeof index === 'number' ? index : current) + 1) + ' / ' + cards.length);
        }
        liveEl.textContent = parts.join(' — ');
      }

      function syncPositions() {
        var total = cards.length;
        for (var i = 0; i < total; i++) {
          var offset = (i - current + total) % total;
          var pos = offset === 0 ? '0' : offset === 1 ? '1' : offset === 2 ? '2' : 'hidden';
          var card = cards[i];
          card.classList.remove('is-swipe-left', 'is-swipe-right', 'is-swipe-skip', 'is-dragging');
          card.style.transform = '';
          card.removeAttribute('data-stamp');
          card.setAttribute('data-pos', pos);
          card.setAttribute('aria-hidden', pos === '0' ? 'false' : 'true');
        }
        if (btnUndo) {
          btnUndo.disabled = history.length === 0;
          btnUndo.style.opacity = history.length ? '1' : '0.45';
        }
        if (progressEl && total) {
          progressEl.style.width = (((current + 1) / total) * 100) + '%';
          if (progressEl.hasAttribute('aria-valuenow')) {
            progressEl.setAttribute('aria-valuenow', String(current + 1));
          }
        }
        updateCounter();
      }

      function finalizePendingExit() {
        clearExitTimer();
        if (!pendingSwipe) {
          busy = false;
          return;
        }
        pendingSwipe = null;
        current = (current + 1) % cards.length;
        busy = false;
        syncPositions();
      }

      function commitSwipe(action) {
        if (!cards.length) return;
        if (busy) finalizePendingExit();

        var card = cards[current];
        var actionBtn = actionButtons[action] || null;
        var nextIndex = (current + 1) % cards.length;

        history.push(current);
        if (history.length > 20) history.shift();

        if (prefersReduced()) {
          current = nextIndex;
          syncPositions();
          announceDeck(actionBtn, card, current);
          return;
        }

        busy = true;
        pendingSwipe = action;
        if (action === 'keep') {
          card.setAttribute('data-stamp', 'keep');
          card.classList.add('is-swipe-right');
        } else if (action === 'delete') {
          card.setAttribute('data-stamp', 'delete');
          card.classList.add('is-swipe-left');
        } else {
          card.classList.add('is-swipe-skip');
        }

        announceDeck(actionBtn, card, nextIndex);
        clearExitTimer();
        exitTimer = window.setTimeout(finalizePendingExit, 340);
      }

      function undoSwipe() {
        if (!cards.length) return;
        if (pendingSwipe) {
          clearExitTimer();
          pendingSwipe = null;
          busy = false;
        } else if (busy) {
          return;
        }
        if (!history.length) return;
        current = history.pop();
        syncPositions();
        announceDeck(btnUndo, cards[current], current);
      }

      if (btnDel) btnDel.addEventListener('click', function () { commitSwipe('delete'); });
      if (btnSkip) btnSkip.addEventListener('click', function () { commitSwipe('skip'); });
      if (btnKeep) btnKeep.addEventListener('click', function () { commitSwipe('keep'); });
      if (btnUndo) btnUndo.addEventListener('click', undoSwipe);

      var iosRadios = document.querySelectorAll('input[name="tidy-ios"]');
      for (var r = 0; r < iosRadios.length; r++) {
        iosRadios[r].addEventListener('change', function () {
          if (pendingSwipe) finalizePendingExit();
        });
      }

      // Pointer drag on top card for tactile swipe gesture.
      var dragStart = null;
      var activeCard = null;
      var activePointerId = null;
      var dragLocked = false;

      function resetDragState() {
        dragStart = null;
        activeCard = null;
        activePointerId = null;
        dragLocked = false;
      }

      function updatePointerCapture(card, pointerId, capture) {
        if (!card || pointerId === null) return;
        try {
          if (capture) {
            if (card.setPointerCapture) card.setPointerCapture(pointerId);
          } else if (
            card.releasePointerCapture &&
            (!card.hasPointerCapture || card.hasPointerCapture(pointerId))
          ) {
            card.releasePointerCapture(pointerId);
          }
        } catch (err) {
          // Synthetic/Playwright or already-ended pointers throw NotFoundError; log unexpected ones.
          if (err && err.name !== 'NotFoundError' && typeof console !== 'undefined' && console.warn) {
            console.warn('Swipe deck pointer capture failed:', err);
          }
        }
      }

      deck.addEventListener('pointerdown', function (e) {
        if (busy || !cards.length || dragStart) return;
        if (e.isPrimary === false) return;
        if (typeof e.button === 'number' && e.button !== 0) return;
        var topCard = cards[current];
        if (!topCard) return;
        activeCard = topCard;
        activePointerId = e.pointerId !== undefined ? e.pointerId : null;
        dragStart = { x: e.clientX, y: e.clientY, dx: 0 };
        dragLocked = false;
      });
      deck.addEventListener('pointermove', function (e) {
        if (!dragStart || !activeCard) return;
        if (activePointerId !== null && e.pointerId !== activePointerId) return;
        var rawDx = e.clientX - dragStart.x;
        var rawDy = e.clientY - dragStart.y;

        if (!dragLocked) {
          if (Math.abs(rawDx) > 6 && Math.abs(rawDx) > Math.abs(rawDy)) {
            dragLocked = true;
            activeCard.classList.add('is-dragging');
            updatePointerCapture(activeCard, activePointerId, true);
          } else if (Math.abs(rawDy) > 6 && Math.abs(rawDy) >= Math.abs(rawDx)) {
            resetDragState();
            return;
          } else {
            return;
          }
        }

        var dy = rawDy * 0.25;
        dragStart.dx = rawDx;
        activeCard.style.transform = 'translate3d(' + rawDx + 'px, ' + dy + 'px, 0) rotate(' + (rawDx * 0.05) + 'deg)';
        if (rawDx > 26) activeCard.setAttribute('data-stamp', 'keep');
        else if (rawDx < -26) activeCard.setAttribute('data-stamp', 'delete');
        else activeCard.removeAttribute('data-stamp');
      });
      function finishDrag(e) {
        if (!dragStart || !activeCard) return;
        if (e && activePointerId !== null && e.pointerId !== undefined && e.pointerId !== activePointerId) return;
        var card = activeCard;
        var dx = dragStart.dx;
        var wasLocked = dragLocked;
        var pointerId = activePointerId;
        var cancelled = e && e.type === 'pointercancel';
        resetDragState();

        if (wasLocked) updatePointerCapture(card, pointerId, false);

        if (!wasLocked) return;
        card.classList.remove('is-dragging');
        card.style.transform = '';
        if (cancelled) {
          syncPositions();
          return;
        }
        if (dx > 60) commitSwipe('keep');
        else if (dx < -60) commitSwipe('delete');
        else syncPositions();
      }
      // Listen at document level so a pointer that leaves the deck before
      // horizontal capture is established still cleans up drag state.
      document.addEventListener('pointerup', finishDrag);
      document.addEventListener('pointercancel', finishDrag);
      window.addEventListener('blur', function () {
        if (!dragStart) return;
        finishDrag({ type: 'pointercancel', pointerId: activePointerId });
      });

      syncPositions();
    }

    // Settings segmented control & toggle switch
    var segButtons = document.querySelectorAll('[data-ios-seg]');
    for (var s = 0; s < segButtons.length; s++) {
      segButtons[s].addEventListener('click', function (event) {
        var btn = event.currentTarget;
        var group = btn.parentElement;
        if (!group) return;
        var peers = group.querySelectorAll('[data-ios-seg]');
        for (var p = 0; p < peers.length; p++) {
          var isMe = peers[p] === btn;
          peers[p].setAttribute('aria-pressed', String(isMe));
          peers[p].classList.toggle('bg-white/20', isMe);
          peers[p].classList.toggle('text-white', isMe);
        }
      });
    }

    var toggleBtn = document.querySelector('[data-ios-toggle]');
    if (toggleBtn) {
      toggleBtn.addEventListener('click', function () {
        var on = toggleBtn.getAttribute('aria-pressed') === 'true';
        var next = !on;
        toggleBtn.setAttribute('aria-pressed', String(next));
        toggleBtn.classList.toggle('bg-[#30d158]', next);
        toggleBtn.classList.toggle('bg-white/20', !next);
        var knob = toggleBtn.querySelector('[data-ios-knob]');
        if (knob) {
          knob.classList.toggle('translate-x-4', next);
          knob.classList.toggle('rtl:-translate-x-4', next);
        }
      });
    }
  }

  // 5) Interactive Mac demo: Scan button jumps to findings, Keep/Delete pills toggle,
  // and Space Explorer treemap tiles highlight breakdown cards.
  function initMacDemo() {
    var scanBtn = document.querySelector('[data-mac-scan]');
    var dupRadio = document.getElementById('tidy-mac-home-duplicates');
    var macRadios = document.querySelectorAll('input[name="tidy-mac-home"]');
    var scanTimer = null;

    function clearScanTimer() {
      if (scanTimer !== null) {
        window.clearTimeout(scanTimer);
        scanTimer = null;
      }
      if (scanBtn) scanBtn.style.transform = '';
    }

    function activateDuplicates() {
      clearScanTimer();
      if (!dupRadio) return;
      dupRadio.checked = true;
      var dupPane = document.querySelector('[data-mac="duplicates"]');
      var focusTarget = dupPane ? dupPane.querySelector('[data-mac-focus-target]') : null;
      if (focusTarget && focusTarget.focus) {
        focusTarget.focus({ preventScroll: true });
      }
    }

    for (var r = 0; r < macRadios.length; r++) {
      macRadios[r].addEventListener('change', clearScanTimer);
    }

    if (scanBtn && dupRadio) {
      scanBtn.addEventListener('click', function () {
        clearScanTimer();
        if (prefersReduced()) {
          activateDuplicates();
          return;
        }
        scanBtn.style.transform = 'scale(0.96)';
        scanTimer = window.setTimeout(activateDuplicates, 220);
      });
    }

    var DECISION_STYLES = {
      keep: {
        active: ['bg-[#30d158]', 'text-black'],
        inactive: ['bg-[#30d158]/20', 'text-[#30d158]'],
        ring: 'ring-[#30d158]/40'
      },
      'delete': {
        active: ['bg-[#d92b21]', 'text-white'],
        inactive: ['bg-[#ff453a]/20', 'text-[#ff7a72]'],
        ring: 'ring-[#ff453a]/40'
      }
    };

    function toggleClasses(el, classes, on) {
      for (var k = 0; k < classes.length; k++) {
        el.classList.toggle(classes[k], on);
      }
    }

    var decisionBtns = document.querySelectorAll('[data-mac-decision]');
    for (var i = 0; i < decisionBtns.length; i++) {
      decisionBtns[i].addEventListener('click', function (event) {
        var btn = event.currentTarget;
        var kind = btn.getAttribute('data-mac-decision');
        var group = btn.parentElement;
        if (!group) return;
        var siblings = group.querySelectorAll('[data-mac-decision]');
        for (var j = 0; j < siblings.length; j++) {
          var s = siblings[j];
          var skind = s.getAttribute('data-mac-decision');
          var cfg = DECISION_STYLES[skind];
          var active = s === btn;
          s.setAttribute('aria-pressed', String(active));
          if (!cfg) continue;
          toggleClasses(s, active ? cfg.inactive : cfg.active, false);
          toggleClasses(s, active ? cfg.active : cfg.inactive, true);
        }
        var card = btn.closest('[data-mac-row]');
        if (card) {
          card.classList.add('ring-1');
          for (var key in DECISION_STYLES) {
            if (Object.prototype.hasOwnProperty.call(DECISION_STYLES, key)) {
              card.classList.toggle(DECISION_STYLES[key].ring, key === kind);
            }
          }
        }
      });
    }

    var treemapTiles = document.querySelectorAll('[data-treemap-tile]');
    var treemapDetails = document.querySelectorAll('[data-treemap-detail]');
    if (treemapTiles.length) {
      for (var t = 0; t < treemapTiles.length; t++) {
        treemapTiles[t].addEventListener('click', function (event) {
          var selected = event.currentTarget;
          var targetId = selected.getAttribute('data-treemap-tile');
          if (!targetId) return;

          for (var ti = 0; ti < treemapTiles.length; ti++) {
            var tile = treemapTiles[ti];
            var isMatch = tile === selected;
            tile.setAttribute('aria-pressed', String(isMatch));
            tile.classList.toggle('ring-2', isMatch);
            tile.classList.toggle('ring-white', isMatch);
          }

          for (var di = 0; di < treemapDetails.length; di++) {
            var detail = treemapDetails[di];
            var detailMatch = detail.getAttribute('data-treemap-detail') === targetId;
            detail.classList.toggle('bg-[#252528]', !detailMatch);
            detail.classList.toggle('ring-1', detailMatch);
            detail.classList.toggle('ring-[#3699ff]/70', detailMatch);
            detail.classList.toggle('bg-[#2d2d31]', detailMatch);
          }
        });
      }
    }
  }

  // 6) Interactive Desktop Cleaner (Snaptitle-style clickable desktop items).
  function initDesktopDemo() {
    var items = document.querySelectorAll('[data-desk-item]');
    var status = document.querySelector('[data-desk-status]');
    if (!items.length) return;

    function updateStatus() {
      if (!status) return;
      var cleaned = 0;
      for (var i = 0; i < items.length; i++) {
        if (items[i].getAttribute('data-cleaned') === 'true') cleaned++;
      }
      status.textContent = cleaned === 0 ? 'Tap to clean' : cleaned + ' / ' + items.length + ' tidy';
    }

    for (var i = 0; i < items.length; i++) {
      items[i].addEventListener('click', function (event) {
        var btn = event.currentTarget;
        var label = btn.querySelector('[data-desk-label]');
        var isCleaned = btn.getAttribute('data-cleaned') === 'true';
        var next = !isCleaned;
        btn.setAttribute('data-cleaned', String(next));
        if (label) {
          label.textContent = next ? btn.getAttribute('data-after') : btn.getAttribute('data-before');
          label.classList.remove('cp-rn');
          void label.offsetWidth;
          label.classList.add('cp-rn');
        }
        updateStatus();
      });
    }
  }

  // 7) Interactive Bento "Tidy Up" / "Undo" button.
  function initBentoTidy() {
    var box = document.querySelector('[data-bento-tidy]');
    if (!box) return;
    var btn = box.querySelector('[data-bento-tidy-btn]');
    var rows = box.querySelectorAll('[data-tidy-row]');
    if (!btn || !rows.length) return;

    btn.addEventListener('click', function () {
      var active = btn.getAttribute('aria-pressed') === 'true';
      var next = !active;
      btn.setAttribute('aria-pressed', String(next));
      btn.textContent = next ? 'Undo' : 'Tidy Up';
      for (var i = 0; i < rows.length; i++) {
        var row = rows[i];
        row.textContent = next ? row.getAttribute('data-tidy-done') : row.getAttribute('data-tidy-row');
        row.classList.toggle('text-cp-orange-deep', next);
        row.classList.toggle('font-bold', next);
      }
    });
  }

  // 8) Interactive Keyboard Shortcut Explorer + live physical key highlighting.
  function initKeyboardExplorer() {
    var tabs = document.querySelectorAll('[data-kb-tab]');
    var rows = document.querySelectorAll('[data-kb-row]');
    var kb = document.querySelector('[data-keyboard]');
    if (!tabs.length || !rows.length || !kb) return;

    function highlightKeys(combo) {
      var allKeys = kb.querySelectorAll('[data-key]');
      for (var i = 0; i < allKeys.length; i++) allKeys[i].classList.remove('on');
      if (!combo) return;
      var parts = combo.split('+');
      for (var p = 0; p < parts.length; p++) {
        var target = kb.querySelector('[data-key="' + parts[p] + '"]');
        if (target) target.classList.add('on');
      }
    }

    function setRowActive(targetRow) {
      for (var i = 0; i < rows.length; i++) {
        var r = rows[i];
        var on = r === targetRow;
        r.classList.toggle('paper', on);
        r.classList.toggle('font-bold', on);
        r.classList.toggle('text-ink', on);
        r.classList.toggle('text-body', !on);
        var kbds = r.querySelectorAll('.cp-kbd');
        for (var k = 0; k < kbds.length; k++) kbds[k].classList.toggle('on', on);
      }
      if (targetRow) highlightKeys(targetRow.getAttribute('data-kb-keys'));
    }

    for (var t = 0; t < tabs.length; t++) {
      tabs[t].addEventListener('click', function (event) {
        var btn = event.currentTarget;
        var group = btn.getAttribute('data-kb-tab');
        for (var i = 0; i < tabs.length; i++) {
          var isMe = tabs[i] === btn;
          tabs[i].setAttribute('aria-selected', String(isMe));
          tabs[i].classList.toggle('bg-ink', isMe);
          tabs[i].classList.toggle('text-canvas', isMe);
          tabs[i].classList.toggle('text-body', !isMe);
        }
        var firstVisible = null;
        for (var r = 0; r < rows.length; r++) {
          var show = rows[r].getAttribute('data-kb-group') === group;
          rows[r].classList.toggle('hidden', !show);
          rows[r].classList.toggle('flex', show);
          if (show && !firstVisible) firstVisible = rows[r];
        }
        setRowActive(firstVisible);
      });
    }

    for (var r = 0; r < rows.length; r++) {
      rows[r].addEventListener('click', function (event) {
        setRowActive(event.currentTarget);
      });
    }

    function mapKey(e) {
      if (e.key === 'Meta' || e.key === 'OS') return 'Meta';
      if (e.key === ' ') return 'Space';
      if (e.key === 'ArrowLeft' || e.key === 'ArrowRight') return e.key;
      if (e.key && e.key.length === 1) return e.key.toLowerCase();
      return null;
    }

    document.addEventListener('keydown', function (e) {
      var k = mapKey(e);
      if (!k) return;
      var el = kb.querySelector('[data-key="' + k + '"]');
      if (el) el.classList.add('on');
    });

    document.addEventListener('keyup', function (e) {
      var k = mapKey(e);
      if (!k) return;
      var el = kb.querySelector('[data-key="' + k + '"]');
      if (el) el.classList.remove('on');
    });
  }

  // 9) Mobile scroll-snap carousel pagination dots.
  function initMobileCarousels() {
    var carousels = document.querySelectorAll('[data-carousel]');
    for (var c = 0; c < carousels.length; c++) {
      (function (track) {
        var name = track.getAttribute('data-carousel');
        var dotsWrap = document.querySelector('[data-dots-for="' + name + '"]');
        var slides = track.children;
        if (!dotsWrap || !slides.length) return;
        dotsWrap.textContent = '';
        var btns = [];
        for (var i = 0; i < slides.length; i++) {
          (function (idx) {
            var b = document.createElement('button');
            b.type = 'button';
            b.setAttribute('aria-label', 'Slide ' + (idx + 1));
            b.setAttribute('aria-current', idx === 0 ? 'true' : 'false');
            b.addEventListener('click', function () {
              slides[idx].scrollIntoView({ behavior: prefersReduced() ? 'auto' : 'smooth', inline: 'start', block: 'nearest' });
            });
            dotsWrap.appendChild(b);
            btns.push(b);
          })(i);
        }
        track.addEventListener('scroll', function () {
          var width = slides[0].getBoundingClientRect().width || 1;
          var active = Math.min(slides.length - 1, Math.max(0, Math.round(track.scrollLeft / width)));
          for (var i = 0; i < btns.length; i++) {
            btns[i].setAttribute('aria-current', i === active ? 'true' : 'false');
          }
        }, { passive: true });
      })(carousels[c]);
    }
  }

  // 10) Mobile segmented switcher for 3 platform cards.
  function initPlanSwitcher() {
    var tabs = document.querySelectorAll('[data-plan-tab]');
    var cards = document.querySelectorAll('[data-plan-card]');
    if (!tabs.length || !cards.length) return;
    for (var i = 0; i < tabs.length; i++) {
      tabs[i].addEventListener('click', function (event) {
        var idx = event.currentTarget.getAttribute('data-plan-tab');
        for (var t = 0; t < tabs.length; t++) {
          var on = tabs[t].getAttribute('data-plan-tab') === idx;
          tabs[t].setAttribute('aria-selected', String(on));
          tabs[t].classList.toggle('bg-ink', on);
          tabs[t].classList.toggle('text-canvas', on);
          tabs[t].classList.toggle('text-body', !on);
        }
        for (var c = 0; c < cards.length; c++) {
          cards[c].classList.toggle('sel', cards[c].getAttribute('data-plan-card') === idx);
        }
      });
    }
  }
})();
