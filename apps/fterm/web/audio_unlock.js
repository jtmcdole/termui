// Tracks WebAudio contexts created before or after initial user gesture and
// resumes any suspended context on the first qualifying user activation gesture.
(function () {
  'use strict';

  const contexts = [];
  const OrigAudioContext = window.AudioContext || window.webkitAudioContext;

  if (typeof OrigAudioContext === 'function') {
    const WrappedAudioContext = function (...args) {
      const ctx = Reflect.construct(
        OrigAudioContext,
        args,
        new.target || OrigAudioContext,
      );
      contexts.push(ctx);
      return ctx;
    };
    WrappedAudioContext.prototype = OrigAudioContext.prototype;
    try {
      Object.setPrototypeOf(WrappedAudioContext, OrigAudioContext);
    } catch (_) {
      // Ignore if environment disallows overriding constructor prototype.
    }
    window.AudioContext = WrappedAudioContext;
    if (window.webkitAudioContext) {
      window.webkitAudioContext = WrappedAudioContext;
    }
  }

  function resumeSuspendedContexts() {
    for (let i = contexts.length - 1; i >= 0; i -= 1) {
      const ctx = contexts[i];
      if (!ctx || ctx.state === 'closed') {
        contexts.splice(i, 1);
        continue;
      }
      if (ctx.state === 'suspended' && typeof ctx.resume === 'function') {
        try {
          const result = ctx.resume();
          if (result && typeof result.catch === 'function') {
            result.catch(function () {});
          }
        } catch (_) {
          // Browsers reject resume if gesture activation expired; later gestures retry.
        }
      }
    }
  }

  const activationEvents = [
    'pointerdown',
    'pointerup',
    'touchend',
    'click',
    'keydown',
  ];
  for (let i = 0; i < activationEvents.length; i += 1) {
    window.addEventListener(activationEvents[i], resumeSuspendedContexts, {
      capture: true,
      passive: true,
    });
  }
})();
