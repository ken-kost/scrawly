// The fill tool (DrawingToolbar's "fill", key F), for both canvases
// (drawing_manager.mjs and demo_board.mjs install it with their stroke
// engine, ensureFillTool).
//
// A press with the fill selected (fillsArea: Ctrl, Alt and the right button
// keep their meaning, erasing and picking) fills the area under the pointer
// with the tool's colour; there is no drag, and the size has no effect. The
// stroke engine hands the press to the owner's takePress, as it does a
// pick, so no stroke starts. The area is worked out once, here, from the
// canvas's stroke list (never from what the screen shows), and becomes one
// more entry of that list, a closed shape: `{path, color, width: 1, fill:
// true}`, which the owner commits like a stroke (the game's op queue, the
// board's "stroke_complete" with its own gesture id, so one undo takes one
// fill back). Everyone renders that same shape.
//
// The work is the fill worker's (priv/static/fill_worker.mjs, a module Web
// Worker served as a static file: none of it is in a page bundle, and none
// of it runs on the main thread): it draws the list at 2 pixels per unit,
// floods the area, grows it by a pixel, traces its outline and holes and
// simplifies them to fit the server's path cap. Here only the press, the
// message and the reply:
//
// * The colour under the press comes from the canvas's paint model
//   (paint_model.mjs, the eyedropper's); an area already in the tool's
//   colour is left as it is (nothing is sent).
// * One fill at a time per tab: a press while one is being worked out is
//   taken and does nothing.
// * The reply is committed only if the canvas is still the one pressed
//   (the owner's begin/commit: the same page instance, still drawing).
// * "too detailed" (the outline doesn't fit the path cap even simplified)
//   and failures show a short notice over the canvas (the owner's
//   `noticeId`, an empty `role="status"` element in the template), gone
//   after NOTICE_MS; nothing blocks.
// * The worker starts when the fill is first chosen (or pressed) and draws
//   the canvas's list ahead then ("prepare"), so the first press finds it
//   ready; it stops after IDLE_MS without a fill, freeing its canvas.
// * While a press would fill, a mouse or a pen over an enabled canvas shows
//   a crosshair (`data-fill` on the svg, app.css), following size_ring.mjs's
//   router like the eyedropper's swatch.
//
// Hologram 0.12 copies this module into every page bundle that can reach
// the importing page: the worker, the canvases and the request in flight
// live in one window slot shared by every copy. The decisions are pure
// (test/js/fill_tool.test.mjs).

import { currentTool, fillsArea, onToolChange } from "./draw_tools.mjs";
import { followPointer, ringShownFor } from "./size_ring.mjs";
import { strokeEngineFor } from "./stroke_engine.mjs";
import { pressNow } from "./eyedropper.mjs";

// fill_worker.mjs's VERSION (a test keeps them equal): in the URL, so a
// browser never runs an older copy of the worker.
export const FILL_WORKER_VERSION = 1;
export const FILL_WORKER_URL = "/fill_worker.mjs?v=" + FILL_WORKER_VERSION;
// How long a notice stays.
export const NOTICE_MS = 2500;
// A fill not answered in this long is given up (the worker is restarted).
export const TIMEOUT_MS = 10000;
// The worker stops after this long without a fill or a "prepare".
export const IDLE_MS = 120000;
// What the drawer is told when a fill can't be made ("nothing", a click
// with nothing of the area's colour under it, says nothing).
export const NOTICES = Object.freeze({
  too_detailed: "that area is too detailed to fill",
  unsupported: "this browser can't fill areas",
  failed: "that area couldn't be filled",
});

const SLOT = "__scrawlyFill";
const NOTICE_TIMER = "__fillNotice";

// ── Pure parts ───────────────────────────────────────────────────────

// Whether two "#rrggbb" colours are the same, in either case.
export function sameColor(a, b) {
  return typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
}

// What the worker gets of a stroke list: plain entries (no DOM nodes, no
// local bookkeeping), oldest first.
export function plainEntries(strokes) {
  const list = Array.isArray(strokes) ? strokes : [];
  const out = [];
  for (let i = 0; i < list.length; i++) {
    const s = list[i];
    if (!s || typeof s.path !== "string" || s.path === "") continue;
    out.push({ id: s.id, path: s.path, color: s.color, width: s.width, fill: s.fill === true });
  }
  return out;
}

// What a worker reply means: {path} to commit, {notice} to show, or {}.
export function replyOutcome(reply) {
  if (reply && typeof reply.path === "string" && reply.path !== "") return { path: reply.path };
  const notice = reply ? NOTICES[reply.error] : undefined;
  return notice ? { notice: notice } : {};
}

// ── The tab's state ──────────────────────────────────────────────────

function fill() {
  if (!window[SLOT]) {
    window[SLOT] = {
      worker: null,
      // The worker's "ready" message, once it came.
      ready: null,
      canvases: new Map(),
      // The request in flight: {id, name, token, color, timer}.
      pending: null,
      nextId: 0,
      idle: null,
      listening: false,
    };
  }
  return window[SLOT];
}

// Tests (and a worker that broke): forget the worker; the next fill starts
// another.
export function resetFillWorker() {
  const st = fill();
  if (st.pending && st.pending.timer) clearTimeout(st.pending.timer);
  st.pending = null;
  if (st.idle) clearTimeout(st.idle);
  st.idle = null;
  if (st.worker) {
    try {
      st.worker.terminate();
    } catch (_e) {}
  }
  st.worker = null;
  st.ready = null;
}

function worker() {
  const st = fill();
  if (st.worker) return st.worker;
  if (typeof Worker !== "function") return null;
  let w;
  try {
    w = new Worker(FILL_WORKER_URL, { type: "module" });
  } catch (_e) {
    return null;
  }
  w.onmessage = function (e) {
    if (fill().worker === w) onReply(e.data);
  };
  // The script didn't load, or the worker broke: the fill in flight fails,
  // the next one starts a new worker.
  w.onerror = function (e) {
    if (e && typeof e.preventDefault === "function") e.preventDefault();
    if (fill().worker !== w) return;
    const pending = fill().pending;
    resetFillWorker();
    if (pending) notify(pending.name, NOTICES.failed);
  };
  st.worker = w;
  return w;
}

function armIdle() {
  const st = fill();
  if (st.idle) clearTimeout(st.idle);
  st.idle = setTimeout(function () {
    const now = fill();
    now.idle = null;
    if (!now.pending) resetFillWorker();
  }, IDLE_MS);
}

function onReply(msg) {
  const st = fill();
  if (!msg || typeof msg !== "object") return;
  if (msg.type === "ready") {
    st.ready = msg;
    return;
  }
  const p = st.pending;
  if (msg.type !== "fill" || !p || msg.id !== p.id) return;
  clearTimeout(p.timer);
  st.pending = null;
  armIdle();
  const canvas = st.canvases.get(p.name);
  if (!canvas) return;
  const outcome = replyOutcome(msg);
  if (outcome.path) canvas.commit(p.token, outcome.path, p.color);
  else if (outcome.notice) notify(p.name, outcome.notice);
}

// ── The notice ───────────────────────────────────────────────────────

function notify(name, text) {
  const canvas = fill().canvases.get(name);
  if (canvas) showFillNotice(canvas.noticeId, text);
}

// `text` in the element `id` for NOTICE_MS (app.css .canvas-notice shows it
// while it has text).
export function showFillNotice(id, text) {
  const el = typeof document !== "undefined" ? document.getElementById(id) : null;
  if (!el) return;
  if (el[NOTICE_TIMER]) clearTimeout(el[NOTICE_TIMER]);
  el.textContent = text;
  el[NOTICE_TIMER] = setTimeout(function () {
    el[NOTICE_TIMER] = null;
    el.textContent = "";
  }, NOTICE_MS);
}

// ── Canvases ─────────────────────────────────────────────────────────

// The worker draws `name`'s list now (the fill was chosen), if its canvas
// is on the page and can be drawn on.
function prepare(name) {
  const canvas = fill().canvases.get(name);
  if (!canvas || !canvasLive(canvas)) return;
  const w = worker();
  if (!w) return;
  w.postMessage({ type: "prepare", canvas: name, strokes: plainEntries(canvas.strokes()) });
  armIdle();
}

function canvasLive(canvas) {
  const engine = strokeEngineFor(canvas.svgId);
  return !!engine && engine.isEnabled() && document.getElementById(canvas.svgId) !== null;
}

function listen() {
  const st = fill();
  if (st.listening) return;
  st.listening = true;
  onToolChange(function (tool) {
    if (tool.tool !== "fill") return;
    for (const name of fill().canvases.keys()) prepare(name);
  });
}

// Registers canvas `name` and returns its stroke engine's takePress for
// fills. opts:
//   svgId, noticeId       the canvas svg and its notice element
//   strokes()             the list the canvas shows, oldest first
//   colorAt(ctx, x, y)    the colour shown at a viewBox point (the paint
//                         model's; ctx: the engine's canStart result)
//   begin(ctx)            a token for the press (null: don't fill), handed
//                         back to commit
//   commit(token, path, color)  adds the fill, if the canvas is still the
//                         one the token names
// Registering a name again replaces it.
export function ensureFillTool(name, opts) {
  fill().canvases.set(name, opts);
  listen();
  followPointer(opts.svgId + " fill", function (p, ctrl, alt) {
    cursor(opts.svgId, p, ctrl, alt);
  });
  // Chosen before this canvas came (a restored page): draw it ahead now.
  if (currentTool().tool === "fill") prepare(name);
  return function (ctx, press, point) {
    return takeFillPress(name, ctx, press, point);
  };
}

// The press, if it fills: true (no stroke starts), whatever comes of it.
export function takeFillPress(name, ctx, press, point) {
  const selected = currentTool();
  if (!fillsArea(selected, press)) return false;
  const st = fill();
  const canvas = st.canvases.get(name);
  if (!canvas || st.pending) return true;
  const x = point[0];
  const y = point[1];
  const ref = canvas.colorAt(ctx, x, y);
  if (sameColor(ref, selected.color)) return true;
  const token = canvas.begin(ctx);
  if (token === null || token === undefined) return true;
  const w = worker();
  if (!w) {
    showFillNotice(canvas.noticeId, NOTICES.unsupported);
    return true;
  }
  st.nextId += 1;
  const id = st.nextId;
  st.pending = {
    id: id,
    name: name,
    token: token,
    color: selected.color.toLowerCase(),
    timer: setTimeout(function () {
      const now = fill();
      if (!now.pending || now.pending.id !== id) return;
      resetFillWorker();
      notify(name, NOTICES.failed);
    }, TIMEOUT_MS),
  };
  w.postMessage({ type: "fill", id: id, canvas: name, strokes: plainEntries(canvas.strokes()), x: x, y: y, ref: ref });
  return true;
}

// Whether a fill is being worked out (tests, the bench).
export function fillPending() {
  return fill().pending !== null;
}

function cursor(svgId, p, ctrl, alt) {
  const svg = document.getElementById(svgId);
  if (!svg) return;
  const engine = strokeEngineFor(svgId);
  const on =
    !!p &&
    p.svgId === svgId &&
    ringShownFor(p.type) &&
    !!engine &&
    engine.isEnabled() &&
    !engine.isDrawing() &&
    fillsArea(currentTool(), pressNow(p.type, ctrl, alt));
  const shown = svg.getAttribute("data-fill") !== null;
  if (on && !shown) svg.setAttribute("data-fill", "");
  else if (!on && shown) svg.removeAttribute("data-fill");
}
