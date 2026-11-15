(function () {
  var hash = window.location.hash || '';
  if (!hash) return;
  var raw = hash.charAt(0) === '#' ? hash.slice(1) : hash;
  if (raw.charAt(0) === '?') raw = raw.slice(1);
  var token = '';
  if (raw.indexOf('=') !== -1) {
    try {
      token = new URLSearchParams(raw).get('token') || '';
    } catch (_) {
      token = '';
    }
  }
  if (token) {
    var consumed = false;
    Object.defineProperty(window, '__ftermConsumeInitialToken', {
      configurable: true,
      enumerable: false,
      writable: false,
      value: function () {
        if (consumed) return '';
        consumed = true;
        var value = token;
        token = '';
        try {
          delete window.__ftermConsumeInitialToken;
        } catch (_) {}
        return value;
      }
    });
  }
  if (window.history && typeof window.history.replaceState === 'function') {
    window.history.replaceState(
      null,
      '',
      window.location.pathname + window.location.search
    );
  }
})();
