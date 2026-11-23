{{flutter_js}}
{{flutter_build_config}}

(function () {
  const splash = document.getElementById('fterm-splash');
  const status = document.getElementById('fterm-splash-status');
  let dismissed = false;
  let fallbackTimer = null;

  function setStatus(text) {
    if (status) {
      status.textContent = text;
    }
  }

  function dismissSplash() {
    if (dismissed || !splash) {
      return;
    }
    dismissed = true;
    if (fallbackTimer !== null) {
      window.clearTimeout(fallbackTimer);
      fallbackTimer = null;
    }
    window.removeEventListener('flutter-first-frame', dismissSplash);

    const removeSplash = function () {
      if (splash.parentNode) {
        splash.parentNode.removeChild(splash);
      }
    };

    const reducedMotion =
      window.matchMedia &&
      window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (reducedMotion) {
      removeSplash();
      return;
    }

    splash.addEventListener('transitionend', removeSplash, { once: true });
    splash.classList.add('fterm-splash-hidden');
    window.setTimeout(removeSplash, 350);
  }

  window.addEventListener('flutter-first-frame', dismissSplash, { once: true });

  const loaderConfig = {
    verboseBuildSelection: true,
  };

  _flutter.loader.load({
    config: loaderConfig,
    onEntrypointLoaded: async function (engineInitializer) {
      setStatus('Starting fterm...');
      const appRunner = await engineInitializer.initializeEngine(loaderConfig);
      await appRunner.runApp();
      if (!dismissed) {
        fallbackTimer = window.setTimeout(dismissSplash, 2500);
      }
    },
  });
})();
