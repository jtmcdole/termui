// Ensures Flutter Web's full-page viewport re-measures devicePixelRatio changes
// across monitor moves and backgrounded browser tabs, even when the browser
// does not emit a visualViewport resize event.
(function () {
  'use strict';

  function currentDpr() {
    const dpr = window.devicePixelRatio;
    return typeof dpr === 'number' && Number.isFinite(dpr) && dpr > 0 ? dpr : 1;
  }

  let lastDpr = currentDpr();
  let wasHidden = document.hidden === true;
  let syncScheduled = false;
  let verifyScheduled = false;
  let activeMediaQuery = null;

  function collectCanvases() {
    const seen = new Set();
    const result = [];

    function addFromRoot(root) {
      if (!root || typeof root.querySelectorAll !== 'function') return;
      const canvases = root.querySelectorAll('canvas');
      for (let i = 0; i < canvases.length; i += 1) {
        const canvas = canvases[i];
        if (!seen.has(canvas)) {
          seen.add(canvas);
          result.push(canvas);
        }
      }
    }

    addFromRoot(document);
    const glassPanes = document.querySelectorAll('flt-glass-pane');
    for (let i = 0; i < glassPanes.length; i += 1) {
      addFromRoot(glassPanes[i].shadowRoot);
    }
    return result;
  }

  function hasStaleCanvasBacking() {
    const dpr = currentDpr();
    const canvases = collectCanvases();
    for (let i = 0; i < canvases.length; i += 1) {
      const canvas = canvases[i];
      if (!canvas || typeof canvas.getBoundingClientRect !== 'function') {
        continue;
      }
      const rect = canvas.getBoundingClientRect();
      if (rect.width < 16 || rect.height < 16) continue;
      const expectedW = Math.round(rect.width * dpr);
      const expectedH = Math.round(rect.height * dpr);
      if (
        Math.abs(canvas.width - expectedW) > 2 ||
        Math.abs(canvas.height - expectedH) > 2
      ) {
        return true;
      }
    }
    return false;
  }

  function dispatchViewportResize() {
    const target = window.visualViewport || window;
    try {
      target.dispatchEvent(new Event('resize'));
    } catch (_) {
      // Ignore synthetic Event restriction if browser disallows VisualViewport dispatch.
      window.dispatchEvent(new Event('resize'));
    }
  }

  function scheduleVerifyAfterFrame() {
    if (verifyScheduled || typeof window.requestAnimationFrame !== 'function') {
      return;
    }
    verifyScheduled = true;
    window.requestAnimationFrame(function () {
      verifyScheduled = false;
      const dpr = currentDpr();
      if (dpr !== lastDpr) {
        lastDpr = dpr;
        subscribeMediaQuery();
        dispatchViewportResize();
        return;
      }
      if (hasStaleCanvasBacking()) {
        dispatchViewportResize();
      }
    });
  }

  function scheduleSync(verifyNextFrame) {
    if (syncScheduled) return;
    syncScheduled = true;
    const raf =
      typeof window.requestAnimationFrame === 'function'
        ? window.requestAnimationFrame.bind(window)
        : function (cb) {
            return setTimeout(cb, 0);
          };
    raf(function () {
      syncScheduled = false;
      lastDpr = currentDpr();
      dispatchViewportResize();
      if (verifyNextFrame) {
        scheduleVerifyAfterFrame();
      }
    });
  }

  function onDprMediaChange() {
    const nextDpr = currentDpr();
    const changed = nextDpr !== lastDpr;
    lastDpr = nextDpr;
    subscribeMediaQuery();
    if (changed || hasStaleCanvasBacking()) {
      scheduleSync(true);
    }
  }

  function subscribeMediaQuery() {
    if (typeof window.matchMedia !== 'function') return;
    if (activeMediaQuery && typeof activeMediaQuery.removeEventListener === 'function') {
      activeMediaQuery.removeEventListener('change', onDprMediaChange);
    }
    const query = window.matchMedia('(resolution: ' + lastDpr + 'dppx)');
    activeMediaQuery = query;
    if (typeof query.addEventListener === 'function') {
      query.addEventListener('change', onDprMediaChange, {
        once: true,
        passive: true,
      });
    } else if (typeof query.addListener === 'function') {
      query.addListener(function legacyListener() {
        query.removeListener(legacyListener);
        onDprMediaChange();
      });
    }
  }

  function handleResumeCheck(forceFromHidden) {
    const nextDpr = currentDpr();
    const dprChanged = nextDpr !== lastDpr;
    if (dprChanged) {
      lastDpr = nextDpr;
      subscribeMediaQuery();
    }
    if (forceFromHidden || dprChanged || hasStaleCanvasBacking()) {
      scheduleSync(true);
    }
  }

  subscribeMediaQuery();

  document.addEventListener(
    'visibilitychange',
    function () {
      if (document.hidden) {
        wasHidden = true;
        return;
      }
      const resumedFromHidden = wasHidden;
      wasHidden = false;
      handleResumeCheck(resumedFromHidden);
    },
    { passive: true },
  );

  window.addEventListener(
    'pageshow',
    function () {
      handleResumeCheck(false);
    },
    { passive: true },
  );

  window.addEventListener(
    'focus',
    function () {
      handleResumeCheck(false);
    },
    { passive: true },
  );
})();
