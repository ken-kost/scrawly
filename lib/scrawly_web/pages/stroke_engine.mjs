// Native stroke engine, shared by the home page's demo board (demo_board.mjs)
// and the in-game canvas (drawing_manager.mjs). It only produces strokes:
// storage and transport stay with its owner, which gets them through
// callbacks.
//
// Input: native pointer events, never Hologram bindings, so moving over a
// canvas runs no action and no render. One pointerdown router (on window,
// capture phase) hands a press on an svg to the engine registered for that
// svg's id, which takes it only when enabled, idle, primary and (for a
// mouse or a pen) the main or the secondary button (a mouse's right button,
// a pen's barrel button). It then captures the pointer and follows only that
// pointerId, with window listeners for the gesture's lifetime: the stroke
// continues outside the canvas and ends on release anywhere (pointerup,
// pointercancel or lostpointercapture).
//
// The owner's getTool gets the press, so the press can choose the gesture's
// tool (draw_tools.mjs gestureStroke: the secondary button, or Ctrl, erases);
// the gesture keeps it until it ends, whatever the keys do meanwhile. A
// press that is no stroke (the colour picker's, eyedropper.mjs) is the
// owner's takePress: it gets the press and its viewBox point first, and
// when it takes the press no gesture starts (nothing is captured, no
// callback runs, no stroke id is used). A
// canvas that can be drawn on opens no context menu (one contextmenu
// listener on window, for every engine's svg), so a right-button drag, or a
// Ctrl+click on a Mac, draws instead; the rest of the page keeps its menu.
// Windows opens the menu on the right button's release, wherever the
// pointer is by then: the one menu a right-button gesture's release opens
// is suppressed too, off the canvas as well.
//
// Coordinates come from the svg's screen CTM (viewBox, letterboxing, scroll
// and zoom included, whatever element was hit), rounded to one decimal.
// Every pointermove's coalesced events are used. The active path is written
// once per animation frame.
//
// Geometry: points closer than MIN_DISTANCE to the last kept one are dropped;
// the path is a chain of quadratic curves through the midpoints. Segments are
// final once the next point is known and only those go to onSegments (the
// chunks peers append); the provisional tail (" L <last point>") stays
// local, and the committed path is the final segments plus the tail. A tap
// commits "M x y L x y", a zero-length segment that round caps draw as a dot.
// A path reaching SPLIT_AT is committed and drawing continues from the same
// point under a new stroke id. Every stroke of one gesture carries the same
// `gesture` id (its first stroke's id), so an owner can undo the gesture
// as one.
//
// Hologram 0.12 copies this module into every page bundle that can reach the
// importing page, so everything shared (the router, the engines by svg id)
// lives on window. The geometry below touches no DOM: test/js/ runs it under
// node --test.

// StrokeRules (the room and DemoBoardChannel) rejects paths over 8_000
// bytes. A split stroke ends at most one segment and its tail (~55
// characters) past this.
export const SPLIT_AT = 7000;
// In viewBox units.
export const MIN_DISTANCE = 1;
// Keeps every number in plain decimal notation (no "1e+21"), as the server's
// path format requires; a captured pointer is never this far off-canvas.
const COORD_LIMIT = 100000;

const ENGINES_SLOT = "__scrawlyStrokeEngines";
const ROUTER_SLOT = "__scrawlyStrokeRouter";
const MENU_SLOT = "__scrawlyStrokeMenuGuard";
// How long after a right-button gesture ends its release's context menu
// (Windows) is still expected.
const MENU_AFTER_RELEASE_MS = 300;
const SECONDARY_BUTTON = 2;

// PointerEvent.button: a mouse's or a pen's press starts a gesture only
// with the main button (left, the pen's tip) or the secondary one (right,
// the pen's barrel button), never the middle, back, forward or a pen's
// eraser button.
const GESTURE_BUTTONS = Object.freeze([0, SECONDARY_BUTTON]);

// ── Geometry (no DOM) ────────────────────────────────────────────────

// One decimal, clamped; null for anything that is not a finite number.
export function roundCoord(value) {
  if (typeof value !== "number" || !Number.isFinite(value)) return null;
  const clamped = Math.max(-COORD_LIMIT, Math.min(COORD_LIMIT, value));
  const rounded = Math.round(clamped * 10) / 10;
  return rounded === 0 ? 0 : rounded;
}

// Client (CSS pixel) coordinates to viewBox coordinates through `m`, the
// inverse of the svg's screen CTM ({a, b, c, d, e, f}, as a DOMMatrix).
export function toViewBox(m, clientX, clientY) {
  if (!m) return null;
  const x = roundCoord(m.a * clientX + m.c * clientY + m.e);
  const y = roundCoord(m.b * clientX + m.d * clientY + m.f);
  return x === null || y === null ? null : [x, y];
}

export function distance(p, q) {
  return Math.hypot(q[0] - p[0], q[1] - p[1]);
}

export function midpoint(p, q) {
  return [roundCoord((p[0] + q[0]) / 2), roundCoord((p[1] + q[1]) / 2)];
}

function fmt(p) {
  return p[0] + " " + p[1];
}

// One stroke's path, built point by point.
//
//   start(p)    -> the first segment, "M x y"
//   add(p)      -> false when p is too close to the last kept point (dropped),
//                  else the segment p finalized: "" for the second point,
//                  " Q <prev> <mid(prev, p)>" from the third on
//   path()      -> the final segments plus the tail " L <last point>"
//   length()    -> path().length, without building it
//   lastPoint() -> the last kept point
export function createStrokeBuilder(minDistance = MIN_DISTANCE) {
  let last = null;
  let added = 0;
  let finalized = "";

  return {
    start(p) {
      last = p;
      added = 0;
      finalized = "M " + fmt(p);
      return finalized;
    },
    add(p) {
      if (!last || !p || distance(last, p) < minDistance) return false;
      added += 1;
      const segment = added >= 2 ? " Q " + fmt(last) + " " + fmt(midpoint(last, p)) : "";
      finalized += segment;
      last = p;
      return segment;
    },
    path() {
      return last ? finalized + " L " + fmt(last) : "";
    },
    length() {
      return last ? finalized.length + 3 + fmt(last).length : 0;
    },
    lastPoint() {
      return last;
    },
  };
}

const NUM = "(-?\\d+(?:\\.\\d+)?)";
const SEP = "[\\s,]+";
const LEADING_L = new RegExp("^\\s*L\\s*" + NUM + SEP + NUM);
const LEADING_Q = new RegExp("^\\s*Q\\s*" + NUM + SEP + NUM + SEP + NUM + SEP + NUM);

// The first delta a viewer gets for a stroke must start the path. One that
// joins mid-stroke (no leading "M") starts at the end point of its first
// segment instead; null when that can't be read.
export function startDelta(delta) {
  if (typeof delta !== "string" || delta === "") return null;
  if (/^\s*M/.test(delta)) return delta;
  let m = delta.match(LEADING_L);
  if (m) return "M " + m[1] + " " + m[2] + delta.slice(m[0].length);
  m = delta.match(LEADING_Q);
  if (m) return "M " + m[3] + " " + m[4] + delta.slice(m[0].length);
  return null;
}

// ── Pointer routing (window singletons) ──────────────────────────────

function engines() {
  if (!window[ENGINES_SLOT]) window[ENGINES_SLOT] = new Map();
  return window[ENGINES_SLOT];
}

// The engine registered for the svg `svgId`, or null (size_ring.mjs shows
// its ring only while that engine is enabled).
export function strokeEngineFor(svgId) {
  return engines().get(svgId) || null;
}

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
}

function svgOf(target) {
  return target && typeof target.closest === "function" ? target.closest("svg[id]") : null;
}

// Whether a press of `pointerType` with `button` can start a gesture.
export function gestureButton(pointerType, button) {
  if (pointerType !== "mouse" && pointerType !== "pen") return true;
  return GESTURE_BUTTONS.includes(button);
}

// A press is looked up by the svg's id when it happens, so an svg that a
// render or a Back/Forward restore replaced is handled like the old one. So
// is a context menu.
function installRouter() {
  if (!window[ROUTER_SLOT]) {
    const route = function (e) {
      const svg = svgOf(e.target);
      if (!svg) return;
      const engine = engines().get(svg.id);
      if (engine) engine.pointerDown(e, svg);
    };
    window.addEventListener("pointerdown", route, true);
    window[ROUTER_SLOT] = route;
  }
  if (!window[MENU_SLOT]) {
    // Over a canvas that can be drawn on, and the menu a right-button
    // gesture's release opens; a viewer's canvas, and everything else,
    // keeps the browser's menu.
    const menu = { releasedAt: null, guard: null };
    menu.guard = function (e) {
      const released = menu.releasedAt !== null && now() - menu.releasedAt < MENU_AFTER_RELEASE_MS;
      menu.releasedAt = null;
      const svg = svgOf(e.target);
      const engine = svg ? engines().get(svg.id) : null;
      if (released || (engine && engine.isEnabled())) e.preventDefault();
    };
    window.addEventListener("contextmenu", menu.guard, true);
    window[MENU_SLOT] = menu;
  }
}

// ── Engine ───────────────────────────────────────────────────────────

// opts:
//   svgId, activePathId     the canvas and its active path (by id)
//   takePress(ctx, press, point)  optional: true when the owner handles the
//                              press itself (point: [x, y] in viewBox
//                              units) and no gesture starts
//   getTool(ctx, press)     -> {color, width} for a new gesture (press: its
//                              pointerdown event); the gesture keeps it,
//                              whole, until it ends (gestureStyle())
//   newStrokeId(ctx)        -> a fresh stroke id
//   canStart(svg)           -> a truthy context passed to every callback of
//                              the gesture, or falsy to ignore the press
//   onStart({id, color, width, delta}, ctx)     delta is "M x y"
//   onSegments({id, color, width, delta}, ctx)  final segments only
//   onEnd({id, gesture, path, color, width}, ctx)  commit it synchronously:
//                              the engine clears the active path (or, on a
//                              split, shows the next stroke) right after, in
//                              the same task. `gesture` is the gesture's
//                              first stroke id, the same for every stroke a
//                              split makes
//   splitAt, minDistance    defaults SPLIT_AT, MIN_DISTANCE
//
// Registering replaces (and disposes) the engine registered for the same
// svg id. Starts disabled. cancel() and disabling drop the stroke in
// progress without any callback: the owner resets its own state.
export function createStrokeEngine(opts) {
  const svgId = opts.svgId;
  const splitAt = opts.splitAt || SPLIT_AT;
  const minDistance = opts.minDistance || MIN_DISTANCE;
  let enabled = false;
  let disposed = false;
  let gesture = null;
  let frame = 0;

  const engine = {
    svgId: svgId,
    pointerDown: pointerDown,
    enable: function () {
      setEnabled(true);
    },
    disable: function () {
      setEnabled(false);
    },
    setEnabled: setEnabled,
    cancel: cancel,
    dispose: dispose,
    isDrawing: function () {
      return gesture !== null;
    },
    // A copy of getTool's result for the gesture in progress, or null.
    gestureStyle: function () {
      return gesture ? { ...gesture.style } : null;
    },
    isEnabled: function () {
      return enabled && !disposed;
    },
    isDisposed: function () {
      return disposed;
    },
  };

  function setEnabled(on) {
    enabled = !!on;
    if (!enabled) cancel();
  }

  function dispose() {
    cancel();
    disposed = true;
    if (engines().get(svgId) === engine) engines().delete(svgId);
  }

  function pointerDown(e, svg) {
    if (disposed || !enabled) return;
    // A press of the pointer we are following means its release was missed.
    if (gesture && e.pointerId === gesture.pointerId) finish();
    if (gesture) return;
    if (e.isPrimary === false) return;
    if (!gestureButton(e.pointerType, e.button)) return;

    // Null while the svg is not rendered.
    const ctm = typeof svg.getScreenCTM === "function" ? svg.getScreenCTM() : null;
    if (!ctm) return;
    const point = toViewBox(ctm.inverse(), e.clientX, e.clientY);
    if (!point) return;
    const ctx = opts.canStart ? opts.canStart(svg) : true;
    if (!ctx) return;

    // No text selection, native drag or compatibility mouse events.
    e.preventDefault();
    if (opts.takePress && opts.takePress(ctx, e, point)) return;
    try {
      svg.setPointerCapture(e.pointerId);
    } catch (_e) {
      // Not an active pointer (e.g. a synthetic event): the window listeners
      // still follow it.
    }

    const tool = (opts.getTool && opts.getTool(ctx, e)) || {};
    gesture = {
      svg: svg,
      pointerId: e.pointerId,
      pointerType: e.pointerType,
      button: e.button,
      ctx: ctx,
      style: tool,
      color: tool.color || "#000000",
      width: tool.width || 2,
      id: null,
      gesture: null,
      builder: null,
      pathEl: null,
    };
    listen(true);
    begin(gesture, point);
  }

  function begin(g, point) {
    g.id = opts.newStrokeId(g.ctx);
    g.gesture = g.id;
    g.builder = createStrokeBuilder(minDistance);
    const delta = g.builder.start(point);
    if (opts.onStart) opts.onStart(info(g, delta), g.ctx);
    scheduleFrame();
  }

  function info(g, delta) {
    return { id: g.id, color: g.color, width: g.width, delta: delta };
  }

  function stroke(g) {
    return { id: g.id, gesture: g.gesture, path: g.builder.path(), color: g.color, width: g.width };
  }

  function onMove(e) {
    const g = gesture;
    if (!g || e.pointerId !== g.pointerId) return;
    // A mouse moving with no button held was released where we never saw it.
    if (g.pointerType === "mouse" && e.buttons === 0) {
      finish();
      return;
    }
    const ctm = g.svg.getScreenCTM();
    if (!ctm) return;
    const inverse = ctm.inverse();
    let events = typeof e.getCoalescedEvents === "function" ? e.getCoalescedEvents() : null;
    if (!events || events.length === 0) events = [e];
    for (let i = 0; i < events.length; i++) {
      addPoint(g, toViewBox(inverse, events[i].clientX, events[i].clientY));
      if (gesture !== g) return;
    }
  }

  function onRelease(e) {
    if (gesture && e.pointerId === gesture.pointerId) finish();
  }

  function addPoint(g, point) {
    if (!point) return;
    const segment = g.builder.add(point);
    if (segment === false) return;
    if (segment && opts.onSegments) opts.onSegments(info(g, segment), g.ctx);
    if (gesture !== g) return;
    if (g.builder.length() >= splitAt) split(g);
    else scheduleFrame();
  }

  // Commit, then continue from the same point under a new id; the active
  // path shows the new stroke in the same task.
  function split(g) {
    const from = g.builder.lastPoint();
    opts.onEnd(stroke(g), g.ctx);
    if (gesture !== g) return;
    g.id = opts.newStrokeId(g.ctx);
    g.builder = createStrokeBuilder(minDistance);
    const delta = g.builder.start(from);
    writeActive(g);
    if (opts.onStart) opts.onStart(info(g, delta), g.ctx);
  }

  function finish() {
    const g = gesture;
    if (!g) return;
    teardown(g);
    try {
      opts.onEnd(stroke(g), g.ctx);
    } finally {
      clearActive(g);
    }
  }

  function cancel() {
    const g = gesture;
    if (!g) return;
    teardown(g);
    clearActive(g);
  }

  function teardown(g) {
    gesture = null;
    listen(false);
    if (g.button === SECONDARY_BUTTON && window[MENU_SLOT]) window[MENU_SLOT].releasedAt = now();
    if (frame) {
      cancelAnimationFrame(frame);
      frame = 0;
    }
    try {
      if (g.svg.hasPointerCapture && g.svg.hasPointerCapture(g.pointerId)) {
        g.svg.releasePointerCapture(g.pointerId);
      }
    } catch (_e) {}
  }

  function listen(on) {
    const method = on ? "addEventListener" : "removeEventListener";
    window[method]("pointermove", onMove, true);
    window[method]("pointerup", onRelease, true);
    window[method]("pointercancel", onRelease, true);
    window[method]("lostpointercapture", onRelease, true);
  }

  function scheduleFrame() {
    if (!frame) frame = requestAnimationFrame(renderFrame);
  }

  function renderFrame() {
    frame = 0;
    if (gesture) writeActive(gesture);
  }

  // The active path may sit in the svg or beside it (the canvases keep it
  // in a layer of its own above the committed strokes).
  function activePath(g) {
    if (!g.pathEl || !g.pathEl.isConnected) {
      g.pathEl = document.getElementById(opts.activePathId);
      g.styled = false;
    }
    return g.pathEl;
  }

  function writeActive(g) {
    const el = activePath(g);
    if (!el) return;
    if (!g.styled) {
      el.setAttribute("stroke", g.color);
      el.setAttribute("stroke-width", g.width);
      g.styled = true;
    }
    el.setAttribute("d", g.builder.path());
  }

  function clearActive(g) {
    const el = activePath(g);
    if (el) el.setAttribute("d", "");
  }

  const previous = engines().get(svgId);
  engines().set(svgId, engine);
  if (previous && previous !== engine) previous.dispose();
  installRouter();
  return engine;
}
