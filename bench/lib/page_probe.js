// Measurement probe injected into every benchmark page before its own
// scripts run (Playwright addInitScript). Exposes window.__bench. It only
// observes and times; the one thing it changes is console.log, see below.
(() => {
  const B = (window.__bench = {
    silenced: 0,
    passLogs: false,
    sse: [],
    ws: [],
    longtasks: [],
    timeline: [],
    frames: null,
    lastKey: null,
  });
  const now = () => performance.now();

  // Hologram 0.12's runtime console.logs every render and every action, and
  // while an action runs every compiled function call, in prod bundles too.
  // With a CDP client attached each of those is serialized to it, which a
  // visitor without DevTools never pays, so they are dropped here (counted
  // in `silenced`) unless `passLogs` is set.
  const log = console.log;
  console.log = function (first) {
    if (!B.passLogs && typeof first === "string" && first.startsWith("Hologram:")) {
      B.silenced++;
      return;
    }
    return log.apply(console, arguments);
  };

  try {
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        B.longtasks.push([e.startTime, e.duration]);
        if (B.longtasks.length > 2000) B.longtasks.splice(0, 1000);
      }
    }).observe({ type: "longtask", buffered: true });
  } catch (_e) {}

  // Arrival of every Realtime broadcast (Hologram's SSE "broadcast" event),
  // stamped before Hologram decodes it.
  const ES = window.EventSource;
  if (ES) {
    const add = ES.prototype.addEventListener;
    ES.prototype.addEventListener = function (type, fn, opts) {
      B.eventSource = this;
      if (type === "broadcast" && typeof fn === "function") {
        const inner = fn;
        fn = function (ev) {
          const t = now();
          const d = typeof ev.data === "string" ? ev.data : "";
          const kind = d.includes("stroke_completed")
            ? "stroke_completed"
            : d.includes("drawing_undone")
              ? "drawing_undone"
              : d.includes("drawing_cleared")
                ? "drawing_cleared"
                : "other";
          const result = inner.call(this, ev);
          B.keep(B.sse, { t, kind, bytes: d.length, handler: now() - t });
          return result;
        };
      }
      return add.call(this, type, fn, opts);
    };
  }

  // Arrival of the demo board's snapshot and strokes (Phoenix channel
  // frames), stamped before Phoenix handles them.
  const WS = window.WebSocket;
  if (WS) {
    // Phoenix handles a frame in the socket's onmessage, synchronously down
    // to the channel's handlers (demo_board.mjs builds the canvas there), so
    // wrapping the handler times the whole of it.
    const onmessage = Object.getOwnPropertyDescriptor(WS.prototype, "onmessage");
    window.WebSocket = class extends WS {
      constructor(...args) {
        super(...args);
        Object.defineProperty(this, "onmessage", {
          configurable: true,
          get: () => onmessage.get.call(this),
          set: (fn) =>
            onmessage.set.call(
              this,
              typeof fn !== "function"
                ? fn
                : function (e) {
                    const d = typeof e.data === "string" ? e.data : "";
                    const kind = d.includes('"demo:board","strokes"')
                      ? "snapshot"
                      : d.includes('"demo:board","stroke"')
                        ? "stroke"
                        : null;
                    const t = now();
                    const result = fn.call(this, e);
                    if (kind) {
                      const rec = { t, kind, bytes: d.length, handler: now() - t };
                      B.keep(B.ws, rec);
                      if (kind === "snapshot" && B.onSnapshot) B.onSnapshot(rec);
                    }
                    return result;
                  }
            ),
        });
      }
    };
  }

  // The page's Realtime stream is open (broadcasts reach it).
  B.sseOpen = () => !!B.eventSource && B.eventSource.readyState === 1;

  // Bounded, so the probe's own records don't show up in the leak check.
  const keep = (list, entry) => {
    list.push(entry);
    if (list.length > 2000) list.splice(0, list.length - 1000);
  };
  B.keep = keep;

  // The layout's decorative glows (.nav-glow, .footer-glow: animated
  // blur(40px) and blur(90px) layers). Headless Chromium composites in
  // software, where re-blurring the footer glow costs ~60 ms a frame and
  // caps a game page at ~15 fps whenever anything near it repaints, which
  // hides the canvas's own cost. drawing_client.mjs hides them (inline
  // display: none, which Hologram's renders leave alone) and measures them
  // separately.
  B.hideGlow = () => {
    document.querySelectorAll(".nav-glow, .footer-glow").forEach((el) => (el.style.display = "none"));
  };

  window.addEventListener("keydown", (e) => (B.lastKey = e.timeStamp), true);

  // Resolves with the time right after the next frame has been rendered.
  B.afterPaint = () => B.nextFrame().then((f) => f.tPaint);

  // The next frame: when it started (its first rAF callback) and when its
  // rendering (rAF callbacks, style, layout, paint) was done.
  B.nextFrame = () =>
    new Promise((resolve) =>
      requestAnimationFrame(() => {
        const tRaf = now();
        const ch = new MessageChannel();
        ch.port1.onmessage = () => resolve({ tRaf, tPaint: now() });
        ch.port2.postMessage(0);
      })
    );

  const count = (id) => {
    const el = document.getElementById(id);
    return el ? el.childElementCount : -1;
  };
  B.counts = () => ({
    viewer: count("game-canvas-strokes"),
    drawer: count("game-canvas-drawer-strokes"),
    demo: count("demo-board-strokes"),
  });

  // Load timeline: from the document's start, every frame in which a
  // canvas's stroke count changed, with the time that frame was rendered.
  let lastKey = "";
  const poll = () => {
    const c = B.counts();
    const key = c.viewer + "," + c.drawer + "," + c.demo;
    if (key !== lastKey) {
      lastKey = key;
      const rec = { raf: now(), counts: c, painted: null };
      B.timeline.push(rec);
      const ch = new MessageChannel();
      ch.port1.onmessage = () => (rec.painted = now());
      ch.port2.postMessage(0);
    }
    if (!B.stopTimeline && now() < 30000) requestAnimationFrame(poll);
  };
  requestAnimationFrame(poll);

  // Waits until canvas group `id` holds `expected` strokes; resolves with
  // the time the DOM got there and the time the next frame was rendered,
  // or null after `timeoutMs`.
  B.waitCount = (id, expected, timeoutMs) =>
    new Promise((resolve) => {
      let done = false;
      const hit = () => count(id) === expected;
      const finish = (tDom) => {
        done = true;
        obs.disconnect();
        B.nextFrame().then(({ tRaf, tPaint }) => resolve({ tDom, tRaf, tPaint }));
      };
      const obs = new MutationObserver(() => {
        if (!done && hit()) finish(now());
      });
      obs.observe(document.documentElement, { childList: true, subtree: true });
      if (hit()) finish(now());
      setTimeout(() => {
        if (!done) {
          done = true;
          obs.disconnect();
          resolve(null);
        }
      }, timeoutMs);
    });

  // The demo board's snapshot again, as a reconnect gets it (Phoenix
  // rejoins and the channel pushes "strokes"): its handling and the
  // rendering of the next frame, on an idle page.
  B.resnapshot = (timeoutMs) =>
    new Promise((resolve) => {
      const inst = window.__scrawlyDemoBoard;
      if (!inst || !inst.socket) return resolve(null);
      const timer = setTimeout(() => {
        B.onSnapshot = null;
        resolve(null);
      }, timeoutMs);
      B.onSnapshot = (rec) => {
        B.onSnapshot = null;
        clearTimeout(timer);
        B.nextFrame().then(({ tRaf, tPaint }) =>
          resolve({ handler: rec.handler, frame: tPaint - tRaf, wall: tPaint - rec.t })
        );
      };
      inst.socket.disconnect(() => inst.socket.connect());
    });

  B.lastSse = (kind, before) => {
    for (let i = B.sse.length - 1; i >= 0; i--) {
      if (B.sse[i].kind === kind && B.sse[i].t <= before) return B.sse[i];
    }
    return null;
  };

  B.longtasksBetween = (t0, t1) =>
    B.longtasks.filter(([s, d]) => s + d > t0 && s < t1).map(([s, d]) => d);

  // Frame timing: the start time of every animation frame and, per frame,
  // the main-thread time from its first rAF callback to the end of its
  // rendering (rAF callbacks, style, layout, paint).
  B.startFrames = () => {
    const f = (B.frames = { raf: [], work: [], on: true });
    const loop = (ts) => {
      if (!f.on) return;
      const t = now();
      f.raf.push(ts);
      const ch = new MessageChannel();
      ch.port1.onmessage = () => f.work.push(now() - t);
      ch.port2.postMessage(0);
      requestAnimationFrame(loop);
    };
    requestAnimationFrame(loop);
  };
  B.stopFrames = () => {
    if (B.frames) B.frames.on = false;
    return B.frames;
  };

  // A pointer gesture on svg `svgId` through `points` (viewBox units), as
  // native pointer events in client coordinates: one move every
  // `intervalMs` (all moves due are sent when the main thread gets to them,
  // as the browser's input queue would), or all in one task when 0.
  B.gesture = (svgId, points, intervalMs) =>
    new Promise((resolve) => {
      const svg = document.getElementById(svgId);
      const m = svg.getScreenCTM();
      const pts = points.map(([x, y]) => [m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f]);
      const ev = (type, p, buttons, button) =>
        new PointerEvent(type, {
          bubbles: true,
          cancelable: true,
          composed: true,
          pointerId: 1,
          pointerType: "mouse",
          isPrimary: true,
          button,
          buttons,
          clientX: p[0],
          clientY: p[1],
        });
      const last = pts[pts.length - 1];
      const t0 = now();
      svg.dispatchEvent(ev("pointerdown", pts[0], 1, 0));
      if (!intervalMs) {
        for (let i = 1; i < pts.length; i++) svg.dispatchEvent(ev("pointermove", pts[i], 1, -1));
        svg.dispatchEvent(ev("pointerup", last, 0, 0));
        resolve({ moves: pts.length - 1, ms: now() - t0 });
        return;
      }
      let i = 1;
      const tick = () => {
        const due = Math.floor((now() - t0) / intervalMs);
        while (i < pts.length && i <= due) {
          svg.dispatchEvent(ev("pointermove", pts[i], 1, -1));
          i++;
        }
        if (i < pts.length) setTimeout(tick, 1);
        else {
          svg.dispatchEvent(ev("pointerup", last, 0, 0));
          resolve({ moves: pts.length - 1, ms: now() - t0 });
        }
      };
      setTimeout(tick, intervalMs);
    });
})();
