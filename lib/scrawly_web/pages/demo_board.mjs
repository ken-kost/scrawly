// Bridge between the shared demo canvas SVG (#demo-board-svg) and the
// `demo:board` Phoenix channel. Drawing mutates SVG paths directly, so
// Hologram never re-renders per pointer move.
//
// While the pointer is down the stroke lives in the active path and is
// streamed to peers as ~20 Hz delta chunks. On release it is committed
// locally as a *pending* stroke node in the same task that clears the active
// path (so no frame is ever painted without it), then `stroke_complete` is
// pushed. The server's `stroke` echo confirms it (and fixes its order); an
// error reply or a push timeout rolls it back.
//
// Store invariant: confirmed strokes in server order, then pending local
// strokes in local order. DOM order inside the svg mirrors it:
//   [defs, grid, confirmed..., pending..., remote overlays..., active path]
//
// Hologram 0.9.2 re-evaluates the page bundle on every <Link> visit, which
// gives this module fresh top-level state. All live state therefore sits in
// one instance object in a window slot, bound to the svg element it was
// created for; every export acts on that instance.

const SVG_ID = "demo-board-svg";
const ACTIVE_PATH_ID = "demo-board-active-path";
const SVG_NS = "http://www.w3.org/2000/svg";
const ERASER_COLOR = "#ffffff";
const ERASER_WIDTH = 18;
const FLUSH_INTERVAL_MS = 50;
// DemoBoardChannel rejects paths of 8_000+ characters. Long gestures are
// committed at this length and continue as a new stroke from the same point.
const SPLIT_AT = 7000;
// Shorter paths (at most a bare "M x y") are never sent.
const MIN_SENT_LENGTH = 6;

const SLOT = "__scrawlyDemoBoard";
const TOOLS_SLOT = "__scrawlyDemoBoardTools";

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

function defaultTools() {
  return { color: "#000000", width: 2, eraser: false };
}

function tools() {
  if (!window[TOOLS_SLOT]) window[TOOLS_SLOT] = defaultTools();
  return window[TOOLS_SLOT];
}

function phoenixAvailable() {
  if (window.Phoenix && window.Phoenix.Socket) return true;
  console.error("Phoenix.Socket not available for demo board");
  return false;
}

// Instance bound to the svg currently in the document, creating one lazily
// when the bound svg is gone or another one is rendered. Keeps tool state.
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
    onLeave: null,
    idCounter: 0,
    // Store: [{id, path, color, width, pending, acked, el}]
    strokes: [],
    // Peers' in-progress strokes: {[strokeId]: {el, path, color, width}}
    remote: {},
    // Stroke being drawn
    activePath: "",
    strokeId: null,
    strokeColor: "#000000",
    strokeWidth: 2,
    seq: 0,
    pendingDelta: "",
    flushTimer: null,
  };

  // Pointer events stop reaching the svg once the cursor leaves it, so end
  // the stroke there instead of resuming it when the cursor comes back.
  inst.onLeave = function () {
    if (alive(inst)) endStrokeOn(inst);
  };
  svgEl.addEventListener("pointerleave", inst.onLeave);

  inst.socket = new window.Phoenix.Socket("/socket", { params: { demo: "true" } });
  inst.socket.connect();

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
  if (inst.flushTimer) {
    clearTimeout(inst.flushTimer);
    inst.flushTimer = null;
  }
  inst.svg.removeEventListener("pointerleave", inst.onLeave);
  clearOverlays(inst);
  try {
    if (inst.channel) inst.channel.leave();
  } catch (_e) {}
  try {
    if (inst.socket) inst.socket.disconnect();
  } catch (_e) {}
  if (window[SLOT] === inst) window[SLOT] = null;
}

// ── DOM helpers ──────────────────────────────────────────────────────

function activePathEl(inst) {
  return inst.svg.querySelector("#" + ACTIVE_PATH_ID);
}

function setActivePathD(inst, d, color, width) {
  const el = activePathEl(inst);
  if (el) {
    el.setAttribute("d", d);
    el.setAttribute("stroke", color);
    el.setAttribute("stroke-width", width);
  }
}

// Committed strokes go before the first remote overlay, or the active path.
function overlayRef(inst) {
  return inst.svg.querySelector("[data-remote-in-progress]") || activePathEl(inst);
}

// DOM node that follows store position `index` (the next entry's node).
function refAfter(inst, index) {
  for (let i = index + 1; i < inst.strokes.length; i++) {
    const el = inst.strokes[i].el;
    if (el && el.parentNode === inst.svg) return el;
  }
  return overlayRef(inst);
}

function insertEl(inst, node, ref) {
  if (ref && ref.parentNode === inst.svg) inst.svg.insertBefore(node, ref);
  else inst.svg.appendChild(node);
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
  const old = inst.svg.querySelectorAll("[data-demo-stroke]");
  for (let i = 0; i < old.length; i++) removeEl(old[i]);

  const frag = document.createDocumentFragment();
  for (let i = 0; i < inst.strokes.length; i++) {
    const entry = inst.strokes[i];
    entry.el = makeStrokeEl(entry);
    frag.appendChild(entry.el);
  }
  insertEl(inst, frag, overlayRef(inst));
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
  const ref = refAfter(inst, at);
  if (entry.el.parentNode !== inst.svg || entry.el.nextSibling !== ref) {
    insertEl(inst, entry.el, ref);
  }
}

// My finished stroke, shown immediately and kept until confirmed or rolled back.
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
  insertEl(inst, entry.el, overlayRef(inst));
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
  clearOverlays(inst);
  renderAll(inst);
}

function clearAll(inst) {
  inst.strokes = [];
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

  let entry = inst.remote[strokeId];
  if (!entry || entry.el.parentNode !== inst.svg) {
    const p = document.createElementNS(SVG_NS, "path");
    p.setAttribute("d", "");
    p.setAttribute("fill", "none");
    p.setAttribute("stroke-linecap", "round");
    p.setAttribute("stroke-linejoin", "round");
    p.setAttribute("data-remote-in-progress", strokeId);
    insertEl(inst, p, activePathEl(inst));
    entry = { el: p, path: "", color: "#000000", width: 2 };
    inst.remote[strokeId] = entry;
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

// Convert pixel offsets (relative to the svg) into viewBox coordinates.
function toViewBox(inst, x, y) {
  const el = inst.svg;
  const vb = el.viewBox && el.viewBox.baseVal;
  if (!vb || !el.clientWidth || !el.clientHeight) return [x, y];
  const scaleX = vb.width / el.clientWidth;
  const scaleY = vb.height / el.clientHeight;
  return [
    Math.round((x * scaleX + Number.EPSILON) * 10) / 10,
    Math.round((y * scaleY + Number.EPSILON) * 10) / 10,
  ];
}

function beginStroke(inst, point, color, width) {
  inst.activePath = "M " + point[0] + " " + point[1];
  inst.strokeId = makeStrokeId(inst);
  inst.strokeColor = color;
  inst.strokeWidth = width;
  inst.seq = 0;
  inst.pendingDelta = inst.activePath;
  setActivePathD(inst, inst.activePath, color, width);
  // Leading-edge flush so peers see the first point within ~1 RTT.
  flushPending(inst);
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

function endStrokeOn(inst) {
  if (inst.flushTimer) {
    clearTimeout(inst.flushTimer);
    inst.flushTimer = null;
  }
  if (!inst.activePath) {
    inst.strokeId = null;
    inst.pendingDelta = "";
    return;
  }
  // Peers' overlays catch up before the completed stroke arrives.
  flushPending(inst);

  const stroke = {
    id: inst.strokeId,
    path: inst.activePath,
    color: inst.strokeColor,
    width: inst.strokeWidth,
  };
  const send = !!stroke.id && stroke.path.length >= MIN_SENT_LENGTH;

  // One synchronous block: the committed node is added and the active path
  // cleared in the same task, so no frame is painted without the stroke.
  if (send) commitLocal(inst, stroke);
  inst.activePath = "";
  inst.strokeId = null;
  inst.pendingDelta = "";
  setActivePathD(inst, "", stroke.color, stroke.width);

  if (send) sendStroke(inst, stroke);
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

// A remote clear cancels the stroke in progress (no stray chunk follows).
function cancelActiveStroke(inst) {
  if (inst.flushTimer) {
    clearTimeout(inst.flushTimer);
    inst.flushTimer = null;
  }
  inst.activePath = "";
  inst.strokeId = null;
  inst.pendingDelta = "";
  setActivePathD(inst, "", inst.strokeColor, inst.strokeWidth);
}

// ── Public API ───────────────────────────────────────────────────────

// Called from HomePage's init-queued `connect_lobby` action. Keeps the live
// instance while it is bound to the svg in the document; otherwise the old
// instance (socket, channel, timers, listeners) is disposed first.
export function connectDemoBoard() {
  // HomePage's init has just reset its tool state to the defaults.
  window[TOOLS_SLOT] = defaultTools();
  const el = document.getElementById(SVG_ID);
  const inst = current();
  if (inst && el && inst.svg === el) return;
  if (inst) dispose(inst);
  if (!el || !phoenixAvailable()) return;
  window[SLOT] = createInstance(el);
}

export function disconnectDemoBoard() {
  const inst = window[SLOT];
  if (inst) dispose(inst);
}

export function startStroke(x, y) {
  const inst = boundInstance();
  if (!inst) return;
  // A missed pointerup must not drop the previous stroke.
  if (inst.activePath) endStrokeOn(inst);
  const t = tools();
  const color = t.eraser ? ERASER_COLOR : t.color;
  const width = t.eraser ? ERASER_WIDTH : t.width;
  beginStroke(inst, toViewBox(inst, x, y), color, width);
}

export function continueStroke(x, y) {
  const inst = current();
  if (!inst || !inst.activePath) return;
  const point = toViewBox(inst, x, y);
  const delta = " L " + point[0] + " " + point[1];
  inst.activePath += delta;
  inst.pendingDelta += delta;

  if (inst.activePath.length >= SPLIT_AT) {
    const color = inst.strokeColor;
    const width = inst.strokeWidth;
    endStrokeOn(inst);
    beginStroke(inst, point, color, width);
  } else {
    setActivePathD(inst, inst.activePath, inst.strokeColor, inst.strokeWidth);
    scheduleFlush(inst);
  }
}

export function endStroke() {
  const inst = current();
  if (inst) endStrokeOn(inst);
}

export function clearBoard() {
  const inst = current();
  if (inst && inst.channel) inst.channel.push("clear", {});
}

export function setColor(color) {
  const t = tools();
  t.color = color;
  t.eraser = false;
}

export function setWidth(width) {
  const t = tools();
  t.width = width;
  t.eraser = false;
}

export function setEraser() {
  tools().eraser = true;
}
