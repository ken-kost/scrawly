// Bridge between the shared demo canvas SVG (#demo-board-svg) and the
// `demo:board` Phoenix channel. Pointer input comes from the native stroke
// engine (stroke_engine.mjs), so Hologram never runs an action or a render
// per pointer move.
//
// While the pointer is down the stroke lives in the active path and its
// final segments are streamed to peers as ~20 Hz delta chunks. On release
// (or when a long gesture is split) it is committed locally as a *pending*
// stroke node in the same task that clears the active path (so no frame is
// ever painted without it), then `stroke_complete` is pushed. The server's
// `stroke` echo confirms it (and fixes its order); an error reply or a push
// timeout rolls it back.
//
// Store invariant: confirmed strokes in server order, then pending local
// strokes in local order, at most MAX_STROKES (like DemoBoardServer). The
// svg's layers are template-rendered and JS fills the two groups:
//   [#demo-board-strokes: confirmed..., pending...]
//   [#demo-board-overlay: peers' strokes in progress]
//   #demo-board-active-path
//
// The board has the game canvas's coordinates (viewBox 0 0 800 450, see
// GameDemo) and its tool: a stroke starts with draw_tools.mjs's tool, which
// HomePage pushes there from its toolbar (DrawingToolbar), or with the eraser
// when pressed with the right button or Ctrl (gestureStroke). With the engine
// come the toolbar's native controls (draw_controls.mjs) and the size ring
// (size_ring.mjs, in #demo-board-ring, shown while the board is connected).
//
// The colour picker (eyedropper.mjs) picks from the store (confirmed and
// pending strokes; peers' strokes in progress are not paint yet): a press
// that picks is the engine's takePress and starts no stroke, and the swatch
// beside the pointer (#demo-board-pick) shows what it would pick. The
// store's paint model (paint_model.mjs, "board") keeps its shapes in step:
// a rollback, a trimmed stroke or an echo with another path forgets one, a
// snapshot keeps those still held (retain), a clear and the instance's end
// drop all; adding a stroke costs nothing (shapes are made on the first
// pick).
//
// Hologram 0.12 copies this module into every page bundle that can reach the
// home page. All live state therefore sits in window slots: one instance
// object bound to the svg element it was created for, and one stroke engine;
// every export acts on those.

import { createStrokeEngine, startDelta } from "./stroke_engine.mjs";
import { currentTool, gestureStroke } from "./draw_tools.mjs";
import { installDrawControls } from "./draw_controls.mjs";
import { ensureSizeRing, refreshSizeRings } from "./size_ring.mjs";
import { CANVAS_COLOR, paintModel } from "./paint_model.mjs";
import { ensurePickSwatch, pickPress } from "./eyedropper.mjs";

const SVG_ID = "demo-board-svg";
const STROKES_ID = "demo-board-strokes";
const OVERLAY_ID = "demo-board-overlay";
const ACTIVE_PATH_ID = "demo-board-active-path";
const RING_ID = "demo-board-ring";
const PICK_ID = "demo-board-pick";
const SVG_NS = "http://www.w3.org/2000/svg";
const FLUSH_INTERVAL_MS = 50;
// DemoBoardChannel drops deltas of 2_000+ bytes: flush before that.
const MAX_CHUNK = 1500;
// DemoBoardServer keeps the newest 500 strokes.
const MAX_STROKES = 500;
// How often a connected board checks that its svg is still in the document.
const LIVENESS_MS = 3000;

const SLOT = "__scrawlyDemoBoard";
const ENGINE_SLOT = "__scrawlyDemoStrokeEngine";

// ── Instance slot ────────────────────────────────────────────────────

function current() {
  const inst = window[SLOT];
  return inst && !inst.disposed ? inst : null;
}

// False (and disposes the instance) once its svg has left the document,
// e.g. after a <Link> navigation away from the home page.
function alive(inst) {
  if (inst.disposed) return false;
  if (!inst.svg.isConnected) {
    dispose(inst);
    return false;
  }
  return true;
}

function phoenixAvailable() {
  if (window.Phoenix && window.Phoenix.Socket) return true;
  console.error("Phoenix.Socket not available for demo board");
  return false;
}

// Instance bound to the svg currently in the document, creating one lazily
// when the bound svg is gone or another one is rendered (e.g. a Back/Forward
// restore, or a render that replaced the svg).
function boundInstance() {
  const el = document.getElementById(SVG_ID);
  if (!el) return null;
  const inst = current();
  if (inst && inst.svg === el) return inst;
  if (inst) dispose(inst);
  if (!phoenixAvailable()) return null;
  window[SLOT] = createInstance(el);
  return window[SLOT];
}

function createInstance(svgEl) {
  const inst = {
    svg: svgEl,
    socket: null,
    channel: null,
    disposed: false,
    idCounter: 0,
    // Store: [{id, path, color, width, pending, acked, el}]
    strokes: [],
    // Peers' in-progress strokes: {[strokeId]: {el, path, color, width}}
    remote: {},
    // Chunk stream of the stroke being drawn (the engine holds its path)
    strokeId: null,
    strokeColor: "#000000",
    strokeWidth: 2,
    seq: 0,
    pendingDelta: "",
    flushTimer: null,
    liveness: null,
  };

  inst.socket = new window.Phoenix.Socket("/socket", { params: { demo: "true" } });
  inst.socket.connect();

  // A <Link> navigation away from the home page (the header) runs no page
  // code: the instance notices its svg is gone at the latest here and
  // closes its socket, instead of when the next board event arrives.
  inst.liveness = setInterval(function () {
    alive(inst);
  }, LIVENESS_MS);

  const channel = inst.socket.channel("demo:board", {});
  inst.channel = channel;

  // Snapshot, sent on every join and rejoin.
  channel.on("strokes", function (payload) {
    if (!alive(inst)) return;
    replaceAll(inst, (payload && payload.strokes) || []);
  });
  // A stroke the server stored, mine included.
  channel.on("stroke", function (payload) {
    if (!alive(inst)) return;
    applyServerStroke(inst, payload || {});
  });
  channel.on("stroke_chunk", function (payload) {
    if (!alive(inst) || !payload) return;
    applyRemoteChunk(inst, payload.stroke_id, payload.delta, payload.color, payload.width);
  });
  channel.on("stroke_abandon", function (payload) {
    if (!alive(inst) || !payload) return;
    removeOverlay(inst, payload.stroke_id);
  });
  channel.on("cleared", function () {
    if (!alive(inst)) return;
    cancelActiveStroke(inst);
    clearAll(inst);
  });

  // Keep the channel on a join error: Phoenix retries the join and sends
  // buffered pushes once it succeeds (or times them out).
  channel.join().receive("error", function (resp) {
    console.warn("demo:board join failed, retrying:", resp);
  });

  return inst;
}

function dispose(inst) {
  if (inst.disposed) return;
  inst.disposed = true;
  if (inst.liveness) clearInterval(inst.liveness);
  cancelActiveStroke(inst);
  clearOverlays(inst);
  paint().clear();
  try {
    if (inst.channel) inst.channel.leave();
  } catch (_e) {}
  try {
    if (inst.socket) inst.socket.disconnect();
  } catch (_e) {}
  if (window[SLOT] === inst) window[SLOT] = null;
}

// ── Paint model (the colour picker's) ────────────────────────────────

function paint() {
  return paintModel("board", {
    present: function () {
      return document.getElementById(SVG_ID) !== null;
    },
  });
}

// The colour the board shows at a viewBox point.
function colorOnBoard(inst, x, y) {
  return inst && !inst.disposed ? paint().colorAt(inst.strokes, x, y) : CANVAS_COLOR;
}

// ── Stroke engine (window singleton) ─────────────────────────────────

function engine() {
  const existing = window[ENGINE_SLOT];
  if (existing && !existing.isDisposed()) return existing;

  window[ENGINE_SLOT] = createStrokeEngine({
    svgId: SVG_ID,
    activePathId: ACTIVE_PATH_ID,
    // The gesture's context is the instance bound to the pressed svg.
    canStart: function (svg) {
      const inst = boundInstance();
      return inst && inst.svg === svg ? inst : null;
    },
    // A press that picks a colour draws nothing (eyedropper.mjs).
    takePress: pickPress(colorOnBoard),
    // The press can make this one gesture erase (the right button, Ctrl).
    getTool: function (_inst, press) {
      return gestureStroke(currentTool(), press);
    },
    newStrokeId: makeStrokeId,
    onStart: function (stroke, inst) {
      if (alive(inst)) beginStroke(inst, stroke);
    },
    onSegments: function (stroke, inst) {
      if (alive(inst)) queueDelta(inst, stroke);
    },
    onEnd: function (stroke, inst) {
      if (alive(inst)) commitStroke(inst, stroke);
    },
  });
  installDrawControls();
  ensureSizeRing(SVG_ID, RING_ID);
  ensurePickSwatch(SVG_ID, PICK_ID, function (x, y) {
    return colorOnBoard(current(), x, y);
  });
  return window[ENGINE_SLOT];
}

// ── DOM helpers ──────────────────────────────────────────────────────

function strokesGroup(inst) {
  return inst.svg.querySelector("#" + STROKES_ID);
}

function overlayGroup(inst) {
  return inst.svg.querySelector("#" + OVERLAY_ID);
}

// DOM node that follows store position `index` (the next entry's node), or
// null for the end of the strokes group.
function refAfter(inst, group, index) {
  for (let i = index + 1; i < inst.strokes.length; i++) {
    const el = inst.strokes[i].el;
    if (el && el.parentNode === group) return el;
  }
  return null;
}

function makeStrokeEl(entry) {
  const p = document.createElementNS(SVG_NS, "path");
  p.setAttribute("fill", "none");
  p.setAttribute("stroke-linecap", "round");
  p.setAttribute("stroke-linejoin", "round");
  p.setAttribute("data-demo-stroke", "true");
  p.setAttribute("data-stroke-id", entry.id);
  updateStrokeEl(p, entry);
  return p;
}

function updateStrokeEl(el, entry) {
  el.setAttribute("d", entry.path);
  el.setAttribute("stroke", entry.color);
  el.setAttribute("stroke-width", entry.width);
}

function removeEl(el) {
  if (el && el.parentNode) el.parentNode.removeChild(el);
}

// Full rebuild, only for snapshots and clears.
function renderAll(inst) {
  const group = strokesGroup(inst);
  if (!group) return;
  const frag = document.createDocumentFragment();
  for (let i = 0; i < inst.strokes.length; i++) {
    const entry = inst.strokes[i];
    entry.el = makeStrokeEl(entry);
    frag.appendChild(entry.el);
  }
  group.replaceChildren(frag);
}

// ── Store (transport-agnostic) ───────────────────────────────────────

function findIndex(inst, id) {
  for (let i = 0; i < inst.strokes.length; i++) {
    if (inst.strokes[i].id === id) return i;
  }
  return -1;
}

// Index of the first pending entry: where confirmed strokes are inserted.
function boundary(inst) {
  for (let i = 0; i < inst.strokes.length; i++) {
    if (inst.strokes[i].pending) return i;
  }
  return inst.strokes.length;
}

function placeAtBoundary(inst, entry) {
  const at = boundary(inst);
  inst.strokes.splice(at, 0, entry);
  const group = strokesGroup(inst);
  if (!group) return;
  const ref = refAfter(inst, group, at);
  if (entry.el.parentNode !== group || entry.el.nextSibling !== ref) {
    group.insertBefore(entry.el, ref);
  }
}

// Oldest first, as DemoBoardServer drops them.
function trim(inst) {
  while (inst.strokes.length > MAX_STROKES) {
    const entry = inst.strokes.shift();
    paint().forget(entry.id);
    removeEl(entry.el);
  }
}

// My finished stroke, shown immediately and kept until confirmed or rolled
// back. Appends exactly one node.
function commitLocal(inst, stroke) {
  const entry = {
    id: stroke.id,
    path: stroke.path,
    color: stroke.color,
    width: stroke.width,
    pending: true,
    acked: false,
    el: null,
  };
  inst.strokes.push(entry);
  entry.el = makeStrokeEl(entry);
  const group = strokesGroup(inst);
  if (group) group.appendChild(entry.el);
  trim(inst);
  return entry;
}

// The server accepted my stroke; its echo will put it in order.
function markAcked(inst, id) {
  const i = findIndex(inst, id);
  if (i >= 0) inst.strokes[i].acked = true;
}

// Server stroke with an id I already hold: adopt the server's version and
// move it to the end of the confirmed part. Never duplicates.
function confirm(inst, stroke) {
  const i = findIndex(inst, stroke.id);
  if (i < 0) return false;
  const entry = inst.strokes.splice(i, 1)[0];
  // The echo's path is normally mine, text for text; another one's shape
  // is made again at the next pick.
  if (paint().has(entry.id) && entry.path !== stroke.path) paint().forget(entry.id);
  entry.pending = false;
  entry.path = stroke.path;
  entry.color = stroke.color;
  entry.width = stroke.width;
  if (!entry.el) entry.el = makeStrokeEl(entry);
  updateStrokeEl(entry.el, entry);
  placeAtBoundary(inst, entry);
  return true;
}

// Rejected or timed out. No-op once an echo or a snapshot confirmed it, or a
// clear removed it.
function rollback(inst, id) {
  const i = findIndex(inst, id);
  if (i < 0 || !inst.strokes[i].pending) return;
  const entry = inst.strokes.splice(i, 1)[0];
  paint().forget(entry.id);
  removeEl(entry.el);
}

// Someone else's stroke: swap its live overlay for the stroke in one task.
function addRemote(inst, stroke) {
  removeOverlay(inst, stroke.id);
  const entry = {
    id: stroke.id,
    path: stroke.path,
    color: stroke.color,
    width: stroke.width,
    pending: false,
    acked: true,
    el: null,
  };
  entry.el = makeStrokeEl(entry);
  placeAtBoundary(inst, entry);
  trim(inst);
}

// Snapshot: the server's list becomes the confirmed part. Pending strokes it
// doesn't contain stay, unless the server already acked them (then a clear
// or a restart dropped them).
function replaceAll(inst, serverStrokes) {
  const confirmed = [];
  const ids = {};
  for (let i = 0; i < serverStrokes.length; i++) {
    const s = normalizeServerStroke(inst, serverStrokes[i]);
    ids[s.id] = true;
    confirmed.push({
      id: s.id,
      path: s.path,
      color: s.color,
      width: s.width,
      pending: false,
      acked: true,
      el: null,
    });
  }
  const keep = inst.strokes.filter(function (e) {
    return e.pending && !e.acked && !ids[e.id];
  });
  inst.strokes = confirmed.concat(keep);
  inst.strokes.splice(0, Math.max(0, inst.strokes.length - MAX_STROKES));
  paint().retain(inst.strokes);
  clearOverlays(inst);
  renderAll(inst);
}

function clearAll(inst) {
  inst.strokes = [];
  paint().clear();
  clearOverlays(inst);
  renderAll(inst);
}

function normalizeServerStroke(inst, s) {
  return {
    id: s.stroke_id || "legacy-" + nextId(inst),
    path: s.path || "",
    color: s.color || "#000000",
    width: s.width || 2,
  };
}

function applyServerStroke(inst, payload) {
  const stroke = normalizeServerStroke(inst, payload);
  removeOverlay(inst, stroke.id);
  if (!confirm(inst, stroke)) addRemote(inst, stroke);
}

// ── Peers' in-progress overlays ──────────────────────────────────────

function applyRemoteChunk(inst, strokeId, delta, color, width) {
  if (!strokeId || !delta) return;
  // Already a stroke here: a late chunk must not leave an overlay behind.
  if (findIndex(inst, strokeId) >= 0) return;
  const group = overlayGroup(inst);
  if (!group) return;

  let entry = inst.remote[strokeId];
  if (!entry) {
    // Joined mid-stroke: start the path at the first point we got.
    delta = startDelta(delta);
    if (!delta) return;
    entry = { el: null, path: "", color: "#000000", width: 2 };
    inst.remote[strokeId] = entry;
  }
  if (!entry.el || entry.el.parentNode !== group) {
    const p = document.createElementNS(SVG_NS, "path");
    p.setAttribute("fill", "none");
    p.setAttribute("stroke-linecap", "round");
    p.setAttribute("stroke-linejoin", "round");
    p.setAttribute("data-remote-in-progress", strokeId);
    group.appendChild(p);
    entry.el = p;
  }
  entry.path += delta;
  entry.color = color || entry.color;
  entry.width = width || entry.width;
  entry.el.setAttribute("d", entry.path);
  entry.el.setAttribute("stroke", entry.color);
  entry.el.setAttribute("stroke-width", entry.width);
}

function removeOverlay(inst, strokeId) {
  const entry = inst.remote[strokeId];
  if (!entry) return;
  removeEl(entry.el);
  delete inst.remote[strokeId];
}

function clearOverlays(inst) {
  Object.keys(inst.remote).forEach(function (id) {
    removeEl(inst.remote[id].el);
  });
  inst.remote = {};
}

// ── Drawing (transport side) ─────────────────────────────────────────

function nextId(inst) {
  inst.idCounter += 1;
  return inst.idCounter;
}

function makeStrokeId(inst) {
  return "d-" + Date.now() + "-" + Math.random().toString(36).slice(2, 8) + "-" + nextId(inst);
}

function beginStroke(inst, stroke) {
  stopFlushTimer(inst);
  inst.strokeId = stroke.id;
  inst.strokeColor = stroke.color;
  inst.strokeWidth = stroke.width;
  inst.seq = 0;
  inst.pendingDelta = stroke.delta;
  // Leading-edge flush so peers see the first point within ~1 RTT.
  flushPending(inst);
}

function queueDelta(inst, stroke) {
  if (stroke.id !== inst.strokeId) return;
  inst.pendingDelta += stroke.delta;
  if (inst.pendingDelta.length >= MAX_CHUNK) {
    stopFlushTimer(inst);
    flushPending(inst);
  } else {
    scheduleFlush(inst);
  }
}

function stopFlushTimer(inst) {
  if (inst.flushTimer) {
    clearTimeout(inst.flushTimer);
    inst.flushTimer = null;
  }
}

function scheduleFlush(inst) {
  if (inst.flushTimer) return;
  inst.flushTimer = setTimeout(function () {
    inst.flushTimer = null;
    if (alive(inst)) flushPending(inst);
  }, FLUSH_INTERVAL_MS);
}

function flushPending(inst) {
  if (!inst.channel || !inst.strokeId || !inst.pendingDelta) return;
  inst.seq += 1;
  inst.channel.push("stroke_chunk", {
    stroke_id: inst.strokeId,
    seq: inst.seq,
    delta: inst.pendingDelta,
    color: inst.strokeColor,
    width: inst.strokeWidth,
  });
  inst.pendingDelta = "";
}

// The engine's onEnd (release, or a long gesture's split). Peers' overlays
// catch up before the completed stroke arrives. The committed node is added
// here and the engine clears the active path right after, in the same task,
// so no frame is painted without the stroke.
function commitStroke(inst, stroke) {
  stopFlushTimer(inst);
  if (stroke.id === inst.strokeId) flushPending(inst);
  inst.strokeId = null;
  inst.pendingDelta = "";
  if (!stroke.id || !stroke.path) return;

  commitLocal(inst, stroke);
  sendStroke(inst, stroke);
}

function sendStroke(inst, stroke) {
  // While the socket is down Phoenix buffers the push; one that is never
  // sent fires "timeout" after 10 s.
  inst.channel
    .push("stroke_complete", {
      stroke_id: stroke.id,
      path: stroke.path,
      color: stroke.color,
      width: stroke.width,
    })
    .receive("ok", function () {
      if (alive(inst)) markAcked(inst, stroke.id);
    })
    .receive("error", function () {
      if (alive(inst)) rollback(inst, stroke.id);
    })
    .receive("timeout", function () {
      if (alive(inst)) rollback(inst, stroke.id);
    });
}

// A remote clear (or the instance's end) cancels the stroke in progress: no
// stray chunk follows and nothing is committed.
function cancelActiveStroke(inst) {
  const e = window[ENGINE_SLOT];
  if (e && inst.strokeId) e.cancel();
  stopFlushTimer(inst);
  inst.strokeId = null;
  inst.pendingDelta = "";
}

// ── Public API ───────────────────────────────────────────────────────

// Called from HomePage's init-queued `connect_lobby` action and on a
// Back/Forward restore, right after the page pushed its tool (setDrawTool).
// Keeps the live instance while it is bound to the svg in the document;
// otherwise the old instance (socket, channel, timers) is disposed first.
// Enables the stroke engine.
export function connectDemoBoard() {
  const el = document.getElementById(SVG_ID);
  const inst = current();
  if (!(inst && el && inst.svg === el)) {
    if (inst) dispose(inst);
    if (!el || !phoenixAvailable()) return;
    window[SLOT] = createInstance(el);
  }
  engine().enable();
  refreshSizeRings();
}

export function disconnectDemoBoard() {
  const e = window[ENGINE_SLOT];
  if (e) e.disable();
  const inst = window[SLOT];
  if (inst) dispose(inst);
  refreshSizeRings();
}

export function clearBoard() {
  const inst = current();
  if (inst && inst.channel) inst.channel.push("clear", {});
}
