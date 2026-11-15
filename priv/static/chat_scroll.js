(function () {
  var CHAT_IDS = ['chat-messages', 'lobby-chat-messages'];
  var tracked = new Map();

  // The game chat on a phone lists the newest line first (`column-reverse`,
  // whose scroll offsets run from 0 at the bottom to negative at the top).
  function isReversed(el) {
    return getComputedStyle(el).flexDirection === 'column-reverse';
  }

  // Keeps the newest line in view: the bottom of the list, or the top of a
  // reversed one.
  function scrollToBottom(el) {
    requestAnimationFrame(function () {
      el.scrollTop = isReversed(el) ? -el.scrollHeight : el.scrollHeight;
    });
  }

  // A reversed list that changes size (a note shows under the input, the
  // screen turns) keeps its offset from the oldest line, which can push the
  // newest out of view; and crossing the phone breakpoint flips the list.
  // Either way: show the newest again. Lists that are not reversed keep
  // their position, as before.
  function watchSize(entry) {
    if (!window.ResizeObserver) return;
    var el = entry.element;
    entry.reversed = isReversed(el);
    entry.resize = new ResizeObserver(function () {
      var reversed = isReversed(el);
      if (reversed || reversed !== entry.reversed) scrollToBottom(el);
      entry.reversed = reversed;
    });
    entry.resize.observe(el);
  }

  function untrack(entry) {
    entry.observer.disconnect();
    if (entry.resize) entry.resize.disconnect();
  }

  function ensureObservers() {
    for (var i = 0; i < CHAT_IDS.length; i++) {
      var id = CHAT_IDS[i];
      var el = document.getElementById(id);
      var current = tracked.get(id);

      if (el && (!current || current.element !== el)) {
        if (current) untrack(current);
        (function (el) {
          var observer = new MutationObserver(function () { scrollToBottom(el); });
          observer.observe(el, { childList: true });
          var entry = { element: el, observer: observer, resize: null };
          watchSize(entry);
          tracked.set(el.id, entry);
          scrollToBottom(el);
        })(el);
      } else if (!el && current) {
        untrack(current);
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
