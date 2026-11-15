// In-game canvas (DrawingCanvas in game_page.ex).
//
// Drawer: pointer input comes from the native stroke engine
// (stroke_engine.mjs), enabled by GamePage through setDrawingEnabled while
// the user is the drawer in :drawing. Finished strokes are committed locally,
// synchronously, into strokeHistory ({id, path, color, width}) and appended
// as one [data-completed] path to the JS-owned #game-canvas-drawer-strokes
// group. Every canvas change (commit, undo by stroke id, clear) then goes to
// the server through a FIFO op queue: only the head is in flight (the
// :send_stroke_op page action), it is resent after OP_RETRY_MS without an ack
// and dropped after OP_MAX_ATTEMPTS. Each op carries {op_epoch, op_seq} so
// the room can ignore resends (RoomServer stroke ops). The stroke's final
// segments stream to viewers over the game socket as ~20 Hz chunks.
//
// Viewers: Hologram renders the completed strokes; the live chunks relayed by
// GameChannel are drawn into the #game-canvas-overlay group until the stroke
// arrives through :stroke_completed (removeRemoteOverlay). Ids of finished or
// dropped overlays are remembered (bounded), so a late chunk cannot recreate
// an orphan overlay.
//
// Hologram 0.12 copies this module into every page bundle that can reach
// GamePage; one mount talks to one copy. The stroke engine is kept on window
// and replaced when another copy takes over, so its callbacks always reach
// the copy GamePage is calling.

import { createStrokeEngine, startDelta } from "./stroke_engine.mjs";

var SVG_NS = "http://www.w3.org/2000/svg";
var SVG_ID = "game-canvas-svg";
var DRAWER_GROUP_ID = "game-canvas-drawer-strokes";
var OVERLAY_ID = "game-canvas-overlay";
var ACTIVE_PATH_ID = "drawing-path";
var MARKER_ID = "game-page-marker";
var ENGINE_SLOT = "__scrawlyGameStrokeEngine";

var copyId = randomToken();
var drawingEnabled = false;

var currentColor = "#000000";
var currentWidth = 2;
var strokeHistory = [];

var strokeIdCounter = 0;
// Chunk stream of the stroke being drawn (the engine holds its path).
var currentStrokeId = null;
var currentStrokeColor = "#000000";
var currentStrokeWidth = 2;
var currentSeq = 0;
var pendingDelta = "";
var flushTimer = null;
var FLUSH_INTERVAL_MS = 50;
// StrokeRules.valid_delta? caps a chunk's delta at 2_000 bytes.
var MAX_CHUNK = 1500;

var OP_RETRY_MS = 5000;
var OP_MAX_ATTEMPTS = 3;
var opEpoch = randomToken();
var opSeq = 0;
var opQueue = [];
var opTimer = null;

var remoteInProgress = {};
var MAX_CLOSED_IDS = 1000;
var closedStrokeIds = new Set();

// Bumped by every GamePage mount; game_channel.mjs uses it to tell a stale
// channel (from an earlier visit) from the current page's one.
var pageGeneration = 0;

function randomToken() {
  if (globalThis.crypto && globalThis.crypto.randomUUID) return globalThis.crypto.randomUUID();
  return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 12);
}

function getPathEl() {
  return document.getElementById(ACTIVE_PATH_ID);
}

// Rendered for the drawer only, so viewers never get JS strokes.
function getDrawerGroup() {
  return document.getElementById(DRAWER_GROUP_ID);
}

function getOverlay() {
  return document.getElementById(OVERLAY_ID);
}

export function gamePagePresent() {
  return document.getElementById(MARKER_ID) !== null;
}

export function gamePageGeneration() {
  return pageGeneration;
}

function makePath(d, color, width) {
  var p = document.createElementNS(SVG_NS, "path");
  p.setAttribute("d", d);
  p.setAttribute("stroke", color);
  p.setAttribute("stroke-width", width);
  p.setAttribute("fill", "none");
  p.setAttribute("stroke-linecap", "round");
  p.setAttribute("stroke-linejoin", "round");
  return p;
}

function makeStrokeNode(s) {
  var p = makePath(s.path, s.color, s.width);
  p.setAttribute("data-completed", "true");
  p.setAttribute("data-stroke-id", s.id);
  return p;
}

// A commit appends one node, an undo removes one; only snapshots (restore,
// rejection, clear, turn reset) rebuild the group.
function appendStrokeNode(s) {
  var group = getDrawerGroup();
  if (group) group.appendChild(makeStrokeNode(s));
}

function removeStrokeNode(id) {
  var group = getDrawerGroup();
  if (!group) return;
  for (var el = group.lastElementChild; el; el = el.previousElementSibling) {
    if (el.getAttribute("data-stroke-id") === id) {
      group.removeChild(el);
      return;
    }
  }
}

function renderCompletedStrokes() {
  var group = getDrawerGroup();
  if (!group) return;
  var frag = document.createDocumentFragment();
  for (var i = 0; i < strokeHistory.length; i++) frag.appendChild(makeStrokeNode(strokeHistory[i]));
  group.replaceChildren(frag);
}

function normalizeStroke(s) {
  return {
    id: s.id,
    path: s.path || "",
    color: s.color || "#000000",
    width: s.width || 2
  };
}

function makeStrokeId() {
  strokeIdCounter += 1;
  return "s-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 8) + "-" + strokeIdCounter;
}

// ---------------------------------------------------------------------------
// Stroke engine (drawer)

function ensureEngine() {
  var engine = window[ENGINE_SLOT];
  if (engine && engine.owner === copyId && !engine.isDisposed()) return engine;
  if (engine) engine.dispose();

  engine = createStrokeEngine({
    svgId: SVG_ID,
    activePathId: ACTIVE_PATH_ID,
    canStart: function () {
      return gamePagePresent() && getDrawerGroup() !== null;
    },
    getTool: function () {
      return { color: currentColor, width: currentWidth };
    },
    newStrokeId: makeStrokeId,
    onStart: beginStroke,
    onSegments: queueSegments,
    onEnd: commitStroke
  });
  engine.owner = copyId;
  engine.setEnabled(drawingEnabled);
  window[ENGINE_SLOT] = engine;
  return engine;
}

// GamePage: on :mounted and whenever is_drawer or the phase changes (the
// rule is GamePage.can_draw?/1). Disabling drops a stroke in progress
// without committing it.
export function setDrawingEnabled(enabled) {
  drawingEnabled = !!enabled;
  if (!drawingEnabled) resetStrokeInProgress();
  ensureEngine().setEnabled(drawingEnabled);
}

// ---------------------------------------------------------------------------
// Stroke in progress (drawer)

function scheduleFlush() {
  if (flushTimer) return;
  flushTimer = setTimeout(function () {
    flushTimer = null;
    flushPending();
  }, FLUSH_INTERVAL_MS);
}

function stopFlushTimer() {
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
}

function flushPending() {
  if (!currentStrokeId || !pendingDelta) return;
  var gs = window.gameSocket;
  if (gs && gs.isInRoom && gs.isInRoom() && gs.sendDrawingStrokeChunk) {
    currentSeq += 1;
    gs.sendDrawingStrokeChunk(currentStrokeId, currentSeq, pendingDelta, currentStrokeColor, currentStrokeWidth);
  }
  pendingDelta = "";
}

// Drops the stroke in progress: the engine's gesture, its chunk stream and
// the active path.
function resetStrokeInProgress() {
  var engine = window[ENGINE_SLOT];
  if (engine) engine.cancel();
  stopFlushTimer();
  currentStrokeId = null;
  currentSeq = 0;
  pendingDelta = "";
  var el = getPathEl();
  if (el) el.setAttribute("d", "");
}

function beginStroke(stroke) {
  stopFlushTimer();
  currentStrokeId = stroke.id;
  currentStrokeColor = stroke.color;
  currentStrokeWidth = stroke.width;
  currentSeq = 0;
  pendingDelta = stroke.delta;
  // Leading-edge flush so viewers see the first point at once.
  flushPending();
}

function queueSegments(stroke) {
  if (stroke.id !== currentStrokeId) return;
  pendingDelta += stroke.delta;
  if (pendingDelta.length >= MAX_CHUNK) {
    stopFlushTimer();
    flushPending();
  } else {
    scheduleFlush();
  }
}

// The engine's onEnd (release, or a long gesture's split): viewers' overlays
// catch up, the stroke is committed locally (one node, before the engine
// clears the active path in the same task) and queued for the room.
function commitStroke(stroke) {
  stopFlushTimer();
  if (stroke.id === currentStrokeId) flushPending();
  currentStrokeId = null;
  currentSeq = 0;
  pendingDelta = "";
  if (!stroke.id || !stroke.path) return;

  var s = { id: stroke.id, path: stroke.path, color: stroke.color, width: stroke.width };
  strokeHistory.push(s);
  appendStrokeNode(s);

  enqueueOp("commit", {
    stroke_id: s.id,
    path: s.path,
    color: s.color,
    width: s.width
  });
}

// ---------------------------------------------------------------------------
// Op queue (drawer)

function clearOpTimer() {
  if (opTimer) {
    clearTimeout(opTimer);
    opTimer = null;
  }
}

function resetOpQueue() {
  clearOpTimer();
  opQueue = [];
}

function enqueueOp(kind, fields) {
  opSeq += 1;
  var op = { op_epoch: opEpoch, op_seq: opSeq, kind: kind };
  for (var k in fields) op[k] = fields[k];
  opQueue.push({ op: op, attempts: 0 });
  if (opQueue.length === 1) sendHead();
}

function sendHead() {
  clearOpTimer();

  // The page is gone: its ops must not reach another page's actions.
  if (!gamePagePresent() || !globalThis.Hologram) {
    resetOpQueue();
    return;
  }

  while (opQueue.length > 0 && opQueue[0].attempts >= OP_MAX_ATTEMPTS) {
    console.warn("stroke op dropped after " + OP_MAX_ATTEMPTS + " attempts", opQueue[0].op.kind, opQueue[0].op.op_seq);
    opQueue.shift();
  }

  var head = opQueue[0];
  if (!head) return;

  head.attempts += 1;
  globalThis.Hologram.dispatchAction("send_stroke_op", "page", head.op);
  opTimer = setTimeout(sendHead, OP_RETRY_MS);
}

function releaseHead(seq) {
  var head = opQueue[0];
  if (!head) return false;
  if (seq !== null && seq !== undefined && head.op.op_seq !== seq) return false;
  opQueue.shift();
  sendHead();
  return true;
}

// :stroke_op_acked (applied, or ignored as a duplicate): send the next op.
export function ackStrokeOp(seq) {
  if (seq === null || seq === undefined) return;
  releaseHead(seq);
}

// :command_denied for a stroke op: drop it and continue.
export function rejectStrokeOp(seq) {
  releaseHead(seq);
}

// :stroke_rejected (invalid stroke or full canvas): show what the room holds.
// setStrokes also drops the queued ops, whose strokes leave the canvas too. A
// late rejection of an op that is no longer the head is stale and ignored.
export function applyRejectedStrokes(seq, strokes) {
  var head = opQueue[0];
  if (seq !== null && seq !== undefined && (!head || head.op.op_seq !== seq)) return;
  setStrokes(strokes);
}

// ---------------------------------------------------------------------------
// Canvas resets

function resetDrawingState() {
  resetStrokeInProgress();
  resetOpQueue();
  strokeHistory = [];
  clearRemoteOverlay();
}

// GamePage :mounted. A new mount drops what an earlier visit of the page left
// in this module (history, queue, overlays), also when that visit was a page
// restored by Back/Forward, which never ran :mounted. Drawing stays off until
// :mounted's setDrawingEnabled.
export function mountCanvas() {
  pageGeneration += 1;
  drawingEnabled = false;
  resetDrawingState();
  ensureEngine().setEnabled(false);
}

// GamePage :mounted, drawer only: the room's strokes at page load go in front
// of anything drawn locally since, so they show at once and can be undone.
// Also after a Back/Forward restore (:room_resynced), whose re-render dropped
// the drawn paths: local strokes are kept, the room's missing ones added.
export function restoreStrokes(strokes) {
  ensureEngine();
  var local = {};
  for (var i = 0; i < strokeHistory.length; i++) local[strokeHistory[i].id] = true;

  var restored = (strokes || [])
    .filter(function (s) { return s && s.id && !local[s.id]; })
    .map(normalizeStroke);

  strokeHistory = restored.concat(strokeHistory);
  renderCompletedStrokes();
}

// The drawer's own clear: queued ops still go out first, then the clear.
export function clearDrawing() {
  resetStrokeInProgress();
  strokeHistory = [];
  clearRemoteOverlay();
  renderCompletedStrokes();
  enqueueOp("clear", {});
}

// The room's strokes (a rejection, or a viewer's snapshot): replaces the
// canvas and drops the stroke in progress and the op queue.
export function setStrokes(strokes) {
  resetStrokeInProgress();
  resetOpQueue();
  strokeHistory = (strokes || []).map(normalizeStroke);
  clearRemoteOverlay();
  renderCompletedStrokes();
}

// New game or turn (every page) and a viewer's :drawing_cleared: an empty
// canvas, nothing in flight.
export function setDrawingPath(path) {
  if (!path || path === "") {
    resetDrawingState();
    renderCompletedStrokes();
  }
}

// The room left :drawing (time up, everyone guessed): the stroke in progress
// can no longer be stored, and live overlays will never complete.
export function endDrawingPhase() {
  resetStrokeInProgress();
  clearRemoteOverlay();
}

export function setToolColor(color) {
  currentColor = color;
}

export function setToolWidth(width) {
  currentWidth = width;
}

// Undo pops the last local stroke and sends its id, so the room removes that
// stroke and no other. Ignored while a stroke is being drawn.
export function undoStroke() {
  var engine = window[ENGINE_SLOT];
  if (engine && engine.isDrawing()) return;
  if (strokeHistory.length === 0) return;

  var stroke = strokeHistory.pop();
  removeStrokeNode(stroke.id);
  enqueueOp("undo", { stroke_id: stroke.id });
}

// ---------------------------------------------------------------------------
// Live overlays (viewers)

function closeStrokeId(strokeId) {
  if (!strokeId) return;
  closedStrokeIds.delete(strokeId);
  closedStrokeIds.add(strokeId);
  if (closedStrokeIds.size > MAX_CLOSED_IDS) {
    closedStrokeIds.delete(closedStrokeIds.values().next().value);
  }
}

function removeOverlayEntry(strokeId) {
  var entry = remoteInProgress[strokeId];
  if (!entry) return;
  if (entry.pathEl && entry.pathEl.parentNode) {
    entry.pathEl.parentNode.removeChild(entry.pathEl);
  }
  delete remoteInProgress[strokeId];
}

function ensureRemotePathEl(strokeId, color, width) {
  var entry = remoteInProgress[strokeId];
  if (entry && entry.pathEl && entry.pathEl.isConnected) return entry;

  var overlay = getOverlay();
  if (!overlay) return null;

  if (!entry) {
    entry = { pathEl: null, path: "", lastSeq: 0, color: color || "#000000", width: width || 2 };
    remoteInProgress[strokeId] = entry;
  }

  // A re-rendered svg dropped the old element: redraw what we already have.
  entry.pathEl = makePath(entry.path, entry.color, entry.width);
  entry.pathEl.setAttribute("data-remote-in-progress", strokeId);
  overlay.appendChild(entry.pathEl);
  return entry;
}

export function applyRemoteChunk(strokeId, seq, delta, color, width) {
  if (!strokeId || !delta) return;
  if (closedStrokeIds.has(strokeId)) return;

  var known = remoteInProgress[strokeId];
  if (known && typeof seq === "number" && seq <= known.lastSeq) return;

  // Joined mid-stroke: start the path at the first point we got.
  if (!known || known.path === "") {
    delta = startDelta(delta);
    if (!delta) return;
  }

  var entry = ensureRemotePathEl(strokeId, color, width);
  if (!entry) return;

  entry.path += delta;
  if (typeof seq === "number") entry.lastSeq = seq;
  entry.color = color || entry.color;
  entry.width = width || entry.width;
  entry.pathEl.setAttribute("d", entry.path);
  entry.pathEl.setAttribute("stroke", entry.color);
  entry.pathEl.setAttribute("stroke-width", entry.width);
}

// :stroke_completed hands the stroke over to Hologram in the same task.
export function removeRemoteOverlay(strokeId) {
  closeStrokeId(strokeId);
  removeOverlayEntry(strokeId);
}

// The drawer's socket went away mid-stroke (GameChannel terminate/2). Chunks
// resent after a rejoin are ignored: the completed stroke still arrives.
export function abandonRemoteStroke(strokeId) {
  closeStrokeId(strokeId);
  removeOverlayEntry(strokeId);
}

function clearRemoteOverlay() {
  Object.keys(remoteInProgress).forEach(function (sid) {
    closeStrokeId(sid);
    removeOverlayEntry(sid);
  });
  remoteInProgress = {};
}
