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
// Who draws: the socket connects with a board token (ScrawlyWeb.BoardToken)
// that HomePage gets in a command's reply and hands to connectDemoBoard; it
// lives only here, in memory (a window slot), never in page state. The
// channel's join reply says whether the socket may draw (`draw`); when it
// may not (no token, or an expired one after a reconnect), when a drawing
// event comes back "unauthorized", or when the server closed the socket
// (the user's tokens were revoked), the page is asked for a fresh token
// (HomePage :board_token_refused, at most every TOKEN_RETRY_MS) and the
// socket reconnects with it.
//
// Undo (undoBoard, HomePage's undo button and Ctrl/Cmd+Z): the server
// marks the caller's own strokes `mine` (in the snapshot and in the
// `stroke` echo; it never sends an owner); my pending strokes are mine too.
// A press takes the newest gesture of mine still shown (the strokes of one
// split gesture share a `gesture` id, which this page knows for its own
// strokes and sends with each stroke_complete; others are one stroke) off
// the canvas at once (hidden, kept in the store) and queues an "undo". The
// server removes the caller's newest gesture and every socket gets
// `stroke_removed` with its ids; the reply carries the same ids. Requests go
// one at a time, and one whose strokes are still pending waits until the
// server has answered for them: a stroke the server rejects is rolled back
// (the press is spent on it, no older stroke goes), one it stores is then
// undone, so an undo right after the release removes that stroke and never
// another. Whatever a request hid that the server did not remove comes back
// when its reply (or timeout) arrives. HomePage's undo button follows
// whether any stroke of mine is shown (:undo_available, sent when that
// changes).
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
// object bound to the svg element it was created for, one stroke engine and
// the board token; every export acts on those.

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
// A refused board asks the page for a fresh token at most this often
// (HomePage's own limit is the same).
const TOKEN_RETRY_MS = 30000;

const SLOT = "__scrawlyDemoBoard";
const ENGINE_SLOT = "__scrawlyDemoStrokeEngine";
const TOKEN_SLOT = "__scrawlyDemoBoardToken";

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

// The board token HomePage handed over last (null: none, watch only).
function boardToken() {
  return window[TOKEN_SLOT] || null;
}

function setBoardToken(token) {
  window[TOKEN_SLOT] = typeof token === "string" && token !== "" ? token : null;
}

function now() {
  return typeof performance !== "undefined" ? performance.now() : Date.now();
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
    // Store: [{id, gesture, path, color, width, mine, pending, acked, hidden, el}]
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
    // The token the socket last connected with, and whether the channel
    // lets it draw (the join reply; null before).
    usedToken: null,
    canDraw: null,
    // When the page was last asked for a fresh token.
    tokenAskedAt: null,
    // Our own disconnect is under way (not the server's close).
    ownClose: false,
    // Undo requests, oldest first: [{targets: [stroke ids], sent}].
    undos: [],
    // What HomePage was last told (:undo_available); its state starts false.
    undoReported: false,
  };

  // Read on every (re)connect, so a reconnect uses the newest token.
  inst.socket = new window.Phoenix.Socket("/socket", {
    params: function () {
      inst.usedToken = boardToken();
      return inst.usedToken ? { board_token: inst.usedToken } : {};
    },
  });
  // The server closes a socket (code 1000, which Phoenix never retries) when
  // the user's tokens were revoked: ask for a token, which names whoever the
  // session is now.
  if (typeof inst.socket.onClose === "function") {
    inst.socket.onClose(function (event) {
      if (inst.ownClose || !alive(inst)) return;
      if (event && event.code === 1000) askForToken(inst, true);
    });
  }
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
  // Strokes an undo took off the board (anyone's undo of their own).
  channel.on("stroke_removed", function (payload) {
    if (!alive(inst) || !payload) return;
    removeStrokes(inst, payload.stroke_ids);
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
  // buffered pushes once it succeeds (or times them out). Phoenix calls the
  // "ok" hook again on every rejoin.
  channel
    .join()
    .receive("ok", function (resp) {
      if (!alive(inst)) return;
      inst.canDraw = !!(resp && resp.draw === true);
      if (!inst.canDraw) askForToken(inst, false);
    })
    .receive("error", function (resp) {
      console.warn("demo:board join failed, retrying:", resp);
    });

  return inst;
}

// The board refused this socket's drawing: HomePage fetches a fresh token
// (:board_token_refused) and hands it to connectDemoBoard, at most every
// TOKEN_RETRY_MS (a server close always asks).
function askForToken(inst, always) {
  const t = now();
  if (!always && inst.tokenAskedAt !== null && t - inst.tokenAskedAt < TOKEN_RETRY_MS) return;
  inst.tokenAskedAt = t;
  if (globalThis.Hologram) globalThis.Hologram.dispatchAction("board_token_refused", "page", {});
}

// The socket connects again with the token in the slot (the channel
// rejoins and gets a fresh snapshot).
function reconnect(inst) {
  inst.ownClose = true;
  inst.socket.disconnect(function () {
    inst.ownClose = false;
    if (!inst.disposed) inst.socket.connect();
  });
}

function dispose(inst) {
  if (inst.disposed) return;
  inst.disposed = true;
  inst.ownClose = true;
  inst.undos = [];
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

// The colour the board shows at a viewBox point (strokes an undo hid are
// not shown).
function colorOnBoard(inst, x, y) {
  return inst && !inst.disposed ? paint().colorAt(shownStrokes(inst.strokes), x, y) : CANVAS_COLOR;
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

// Full rebuild, only for snapshots and clears. Hidden entries get a node
// too (an undo the server refuses puts it back), outside the group.
function renderAll(inst) {
  const group = strokesGroup(inst);
  if (!group) return;
  const frag = document.createDocumentFragment();
  for (let i = 0; i < inst.strokes.length; i++) {
    const entry = inst.strokes[i];
    entry.el = makeStrokeEl(entry);
    if (!entry.hidden) frag.appendChild(entry.el);
  }
  group.replaceChildren(frag);
}

// Puts a hidden entry's node back at its place in the group.
function showEntry(inst, index) {
  const entry = inst.strokes[index];
  entry.hidden = false;
  const group = strokesGroup(inst);
  if (!group) return;
  if (!entry.el) entry.el = makeStrokeEl(entry);
  group.insertBefore(entry.el, refAfter(inst, group, index));
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
  if (entry.hidden) {
    removeEl(entry.el);
    return;
  }
  const ref = refAfter(inst, group, at);
  if (entry.el.parentNode !== group || entry.el.nextSibling !== ref) {
    group.insertBefore(entry.el, ref);
  }
}

// Oldest first, as DemoBoardServer drops them: a trimmed stroke can't be
// undone any more (a request left without strokes is spent).
function trim(inst) {
  if (inst.strokes.length <= MAX_STROKES) return;
  while (inst.strokes.length > MAX_STROKES) {
    const entry = inst.strokes.shift();
    paint().forget(entry.id);
    removeEl(entry.el);
  }
  pumpUndo(inst);
}

// My finished stroke, shown immediately and kept until confirmed or rolled
// back. Appends exactly one node.
function commitLocal(inst, stroke) {
  const entry = {
    id: stroke.id,
    gesture: stroke.gesture || stroke.id,
    path: stroke.path,
    color: stroke.color,
    width: stroke.width,
    mine: true,
    pending: true,
    acked: false,
    hidden: false,
    el: null,
  };
  inst.strokes.push(entry);
  entry.el = makeStrokeEl(entry);
  const group = strokesGroup(inst);
  if (group) group.appendChild(entry.el);
  trim(inst);
  reportUndo(inst);
  return entry;
}

// The server accepted my stroke; its echo will put it in order.
function markAcked(inst, id) {
  const i = findIndex(inst, id);
  if (i >= 0) inst.strokes[i].acked = true;
  pumpUndo(inst);
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
  entry.mine = stroke.mine;
  entry.path = stroke.path;
  entry.color = stroke.color;
  entry.width = stroke.width;
  if (!entry.el) entry.el = makeStrokeEl(entry);
  updateStrokeEl(entry.el, entry);
  placeAtBoundary(inst, entry);
  reportUndo(inst);
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
  pumpUndo(inst);
  reportUndo(inst);
}

// Someone else's stroke (or mine from another tab of this browser): swap
// its live overlay for the stroke in one task.
function addRemote(inst, stroke) {
  removeOverlay(inst, stroke.id);
  const entry = {
    id: stroke.id,
    gesture: stroke.id,
    path: stroke.path,
    color: stroke.color,
    width: stroke.width,
    mine: stroke.mine,
    pending: false,
    acked: true,
    hidden: false,
    el: null,
  };
  entry.el = makeStrokeEl(entry);
  placeAtBoundary(inst, entry);
  trim(inst);
  reportUndo(inst);
}

// Strokes the server took off the board (an undo), whoever drew them.
function removeStrokes(inst, ids) {
  const list = Array.isArray(ids) ? ids : [];
  for (let k = 0; k < list.length; k++) {
    const i = findIndex(inst, list[k]);
    if (i < 0) continue;
    const entry = inst.strokes.splice(i, 1)[0];
    paint().forget(entry.id);
    removeEl(entry.el);
  }
  pumpUndo(inst);
  reportUndo(inst);
}

// Snapshot: the server's list becomes the confirmed part. Pending strokes it
// doesn't contain stay, unless the server already acked them (then a clear
// or a restart dropped them).
// Strokes an undo request still waits on stay hidden; my strokes known
// here keep their gesture.
function replaceAll(inst, serverStrokes) {
  const confirmed = [];
  const ids = {};
  const hide = undoTargets(inst);
  const gestures = {};
  for (let i = 0; i < inst.strokes.length; i++) gestures[inst.strokes[i].id] = inst.strokes[i].gesture;
  for (let i = 0; i < serverStrokes.length; i++) {
    const s = normalizeServerStroke(inst, serverStrokes[i]);
    ids[s.id] = true;
    confirmed.push({
      id: s.id,
      gesture: (s.mine && gestures[s.id]) || s.id,
      path: s.path,
      color: s.color,
      width: s.width,
      mine: s.mine,
      pending: false,
      acked: true,
      hidden: hide[s.id] === true,
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
  pumpUndo(inst);
  reportUndo(inst);
}

function clearAll(inst) {
  inst.strokes = [];
  paint().clear();
  clearOverlays(inst);
  renderAll(inst);
  pumpUndo(inst);
  reportUndo(inst);
}

// `mine` only when the server says so (it never sends whose a stroke is).
function normalizeServerStroke(inst, s) {
  return {
    id: s.stroke_id || "legacy-" + nextId(inst),
    path: s.path || "",
    color: s.color || "#000000",
    width: s.width || 2,
    mine: s.mine === true,
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
      gesture: stroke.gesture || stroke.id,
      path: stroke.path,
      color: stroke.color,
      width: stroke.width,
    })
    .receive("ok", function () {
      if (alive(inst)) markAcked(inst, stroke.id);
    })
    .receive("error", function (resp) {
      if (!alive(inst)) return;
      rollback(inst, stroke.id);
      if (resp && resp.reason === "unauthorized") askForToken(inst, false);
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

// ── Undo (my own strokes) ────────────────────────────────────────────

// The strokes the canvas shows: all but those an undo hid.
export function shownStrokes(strokes) {
  for (let i = 0; i < strokes.length; i++) {
    if (strokes[i].hidden) return strokes.filter(function (e) { return !e.hidden; });
  }
  return strokes;
}

// Whether any stroke of mine is shown (the undo button).
export function hasOwnStroke(strokes) {
  for (let i = strokes.length - 1; i >= 0; i--) {
    if (strokes[i].mine && !strokes[i].hidden) return true;
  }
  return false;
}

// The ids an undo press takes off the canvas, newest first: the newest
// shown stroke of mine and every shown stroke of mine in its gesture.
// Pure; [] when none of mine is shown.
export function lastOwnGesture(strokes) {
  let gesture = null;
  const ids = [];
  for (let i = strokes.length - 1; i >= 0; i--) {
    const e = strokes[i];
    if (!e.mine || e.hidden) continue;
    const key = e.gesture || e.id;
    if (gesture === null) gesture = key;
    if (key === gesture) ids.push(e.id);
  }
  return ids;
}

// Ids hidden by the queued requests.
function undoTargets(inst) {
  const ids = {};
  for (let i = 0; i < inst.undos.length; i++) {
    for (let j = 0; j < inst.undos[i].targets.length; j++) ids[inst.undos[i].targets[j]] = true;
  }
  return ids;
}

// Sends the head request once the server has answered for every stroke of
// it still pending. A request whose strokes are all gone (rolled back,
// removed, trimmed, cleared) is spent.
function pumpUndo(inst) {
  while (inst.undos.length > 0) {
    const head = inst.undos[0];
    if (head.sent) return;
    let held = 0;
    let waiting = false;
    for (let k = 0; k < head.targets.length; k++) {
      const i = findIndex(inst, head.targets[k]);
      if (i < 0) continue;
      held += 1;
      if (inst.strokes[i].pending && !inst.strokes[i].acked) waiting = true;
    }
    if (held === 0) {
      inst.undos.shift();
      continue;
    }
    if (waiting || !inst.channel) return;
    head.sent = true;
    inst.channel
      .push("undo", {})
      .receive("ok", function (resp) {
        if (alive(inst)) finishUndo(inst, head, resp && resp.stroke_ids);
      })
      .receive("error", function (resp) {
        if (!alive(inst)) return;
        if (resp && resp.reason === "unauthorized") askForToken(inst, false);
        finishUndo(inst, head, []);
      })
      .receive("timeout", function () {
        if (alive(inst)) finishUndo(inst, head, []);
      });
    return;
  }
}

// The server's answer: what it removed goes (its stroke_removed follows,
// and finds nothing left to do); what the request hid and the server kept
// comes back.
function finishUndo(inst, head, removed) {
  const at = inst.undos.indexOf(head);
  if (at >= 0) inst.undos.splice(at, 1);
  const gone = {};
  if (Array.isArray(removed)) for (let k = 0; k < removed.length; k++) gone[removed[k]] = true;
  for (let k = 0; k < head.targets.length; k++) {
    if (gone[head.targets[k]]) continue;
    const i = findIndex(inst, head.targets[k]);
    if (i >= 0 && inst.strokes[i].hidden) showEntry(inst, i);
  }
  removeStrokes(inst, removed);
}

// HomePage's undo button follows hasOwnStroke (:undo_available), told only
// when it changes and only while the board is on the page.
function reportUndo(inst) {
  const available = hasOwnStroke(inst.strokes);
  if (available === inst.undoReported) return;
  if (inst.disposed || !inst.svg.isConnected || !globalThis.Hologram) return;
  inst.undoReported = available;
  globalThis.Hologram.dispatchAction("undo_available", "page", { available: available });
}

// ── Public API ───────────────────────────────────────────────────────

// Called with a board token (a string, or null: watch only) from HomePage's
// replies that carry one (:board_token_ready after the page loaded or the
// board refused its token, :lobby_resynced after a Back/Forward restore);
// without an argument the token handed over last is used. Keeps the live
// instance while it is bound to the svg in the document, reconnecting its
// socket when the token changed; otherwise the old instance (socket,
// channel, timers) is disposed first. Enables the stroke engine.
export function connectDemoBoard(token) {
  if (token !== undefined) setBoardToken(token);
  const el = document.getElementById(SVG_ID);
  const inst = current();
  if (!(inst && el && inst.svg === el)) {
    if (inst) dispose(inst);
    if (!el || !phoenixAvailable()) return;
    window[SLOT] = createInstance(el);
  } else if (inst.usedToken !== boardToken()) {
    reconnect(inst);
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

// Takes back my newest gesture on the board (see "Undo" above). Ignored
// while a stroke is being drawn, and when none of mine is shown.
export function undoBoard() {
  const inst = current();
  if (!inst || !alive(inst)) return;
  const e = window[ENGINE_SLOT];
  if (e && e.isDrawing()) return;
  const targets = lastOwnGesture(inst.strokes);
  if (targets.length === 0) return;
  for (let k = 0; k < targets.length; k++) {
    const entry = inst.strokes[findIndex(inst, targets[k])];
    entry.hidden = true;
    removeEl(entry.el);
  }
  inst.undos.push({ targets: targets, sent: false });
  pumpUndo(inst);
  reportUndo(inst);
}
