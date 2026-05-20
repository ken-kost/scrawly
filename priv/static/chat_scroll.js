(function () {
  var CHAT_IDS = ['chat-messages', 'lobby-chat-messages'];
  var tracked = new Map();

  function scrollToBottom(el) {
    requestAnimationFrame(function () {
      el.scrollTop = el.scrollHeight;
    });
  }

  function ensureObservers() {
    for (var i = 0; i < CHAT_IDS.length; i++) {
      var id = CHAT_IDS[i];
      var el = document.getElementById(id);
      var current = tracked.get(id);

      if (el && (!current || current.element !== el)) {
        if (current) current.observer.disconnect();
        (function (el) {
          var observer = new MutationObserver(function () { scrollToBottom(el); });
          observer.observe(el, { childList: true });
          tracked.set(el.id, { element: el, observer: observer });
          scrollToBottom(el);
        })(el);
      } else if (!el && current) {
        current.observer.disconnect();
        tracked.delete(id);
      }
    }
  }

  function start() {
    ensureObservers();
    new MutationObserver(ensureObservers).observe(document.body, {
      childList: true, subtree: true
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
