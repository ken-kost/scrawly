// In-game canvas (DrawingCanvas in game_page.ex).
//
// Drawer: strokes are drawn and committed locally, synchronously, into
// strokeHistory ({id, path, color, width}) and rendered as [data-completed]
// paths before #drawing-path. Every canvas change (commit, undo by stroke id,
// clear) then goes to the server through a FIFO op queue: only the head is in
// flight (the :send_stroke_op page action), it is resent after OP_RETRY_MS
// without an ack and dropped after OP_MAX_ATTEMPTS. Each op carries
// {op_epoch, op_seq} so the room can ignore resends (RoomServer stroke ops).
//
// Viewers: Hologram renders the completed strokes; the live chunks relayed by
// GameChannel are drawn into the #game-canvas-overlay group until the stroke
// arrives through :stroke_completed (removeRemoteOverlay). Ids of finished or
// dropped overlays are remembered (bounded), so a late chunk cannot recreate
// an orphan overlay.

var SVG_NS = "http://www.w3.org/2000/svg";
var SVG_ID = "game-canvas-svg";
var OVERLAY_ID = "game-canvas-overlay";
var ACTIVE_PATH_ID = "drawing-path";
var MARKER_ID = "game-page-marker";

var currentColor = "#000000";
var currentWidth = 2;
var strokeHistory = [];
var currentStrokePath = "";

var strokeIdCounter = 0;
var currentStrokeId = null;
var currentSeq = 0;
var pendingDelta = "";
var flushTimer = null;
var FLUSH_INTERVAL_MS = 50;

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

function getSvg() {
  return document.getElementById(SVG_ID);
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

function setActivePathD(d) {
  var el = getPathEl();
  if (el) {
    el.setAttribute("d", d);
    el.setAttribute("stroke", currentColor);
    el.setAttribute("stroke-width", currentWidth);
  }
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

// Drawer only: viewers' completed strokes are rendered by Hologram.
function renderCompletedStrokes() {
  var svg = getSvg();
  if (!svg) return;

  var old = svg.querySelectorAll("[data-completed]");
  for (var i = 0; i < old.length; i++) {
    old[i].remove();
  }

  var activePath = getPathEl();
  if (!activePath || strokeHistory.length === 0) return;

  var frag = document.createDocumentFragment();
  for (var j = 0; j < strokeHistory.length; j++) {
    var s = strokeHistory[j];
    var p = makePath(s.path, s.color, s.width);
    p.setAttribute("data-completed", "true");
    p.setAttribute("data-stroke-id", s.id);
    frag.appendChild(p);
  }
  activePath.parentNode.insertBefore(frag, activePath);
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
// Stroke in progress (drawer)

function scheduleFlush() {
  if (flushTimer) return;
  flushTimer = setTimeout(function () {
    flushTimer = null;
    flushPending();
  }, FLUSH_INTERVAL_MS);
}

function flushPending() {
  if (!currentStrokeId || !pendingDelta) return;
  var gs = window.gameSocket;
  if (gs && gs.isInRoom && gs.isInRoom() && gs.sendDrawingStrokeChunk) {
    currentSeq += 1;
    gs.sendDrawingStrokeChunk(currentStrokeId, currentSeq, pendingDelta, currentColor, currentWidth);
  }
  pendingDelta = "";
}

function resetStrokeInProgress() {
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  currentStrokeId = null;
  currentStrokePath = "";
  currentSeq = 0;
  pendingDelta = "";
  setActivePathD("");
}

export function startStroke(x, y) {
  // A gesture that never got its pointer up is committed, not dropped:
  // viewers already have its overlay.
  if (currentStrokeId) endStroke();

  currentStrokePath = "M " + x + " " + y;
  currentStrokeId = makeStrokeId();
  currentSeq = 0;
  pendingDelta = currentStrokePath;
  setActivePathD(currentStrokePath);
  flushPending();
}

export function continueStroke(x, y) {
  if (!currentStrokeId) return;
  var delta = " L " + x + " " + y;
  currentStrokePath += delta;
  pendingDelta += delta;
  setActivePathD(currentStrokePath);
  scheduleFlush();
}

export function endStroke() {
  if (!currentStrokeId) return "";

  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  flushPending();

  var stroke = { id: currentStrokeId, path: currentStrokePath, color: currentColor, width: currentWidth };
  strokeHistory.push(stroke);
  renderCompletedStrokes();
  resetStrokeInProgress();

  enqueueOp("commit", {
    stroke_id: stroke.id,
    path: stroke.path,
    color: stroke.color,
    width: stroke.width
  });

  return "";
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
// restored by Back/Forward, which never ran :mounted.
export function mountCanvas() {
  pageGeneration += 1;
  resetDrawingState();
}

// GamePage :mounted, drawer only: the room's strokes at page load go in front
// of anything drawn locally since, so they show at once and can be undone.
// Also after a Back/Forward restore (:room_resynced), whose re-render dropped
// the drawn paths: local strokes are kept, the room's missing ones added.
export function restoreStrokes(strokes) {
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

// The room's strokes (a rejection, or a viewer's :drawing_undone): replaces
// the canvas and drops the stroke in progress and the op queue.
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

export function getDrawingPath() {
  var parts = strokeHistory.map(function (s) { return s.path; });
  if (currentStrokePath) parts.push(currentStrokePath);
  return parts.join(" ");
}

export function resetSentLength() {
}

export function setToolColor(color) {
  currentColor = color;
  var el = getPathEl();
  if (el) el.setAttribute("stroke", color);
}

export function setToolWidth(width) {
  currentWidth = width;
  var el = getPathEl();
  if (el) el.setAttribute("stroke-width", width);
}

// Undo pops the last local stroke and sends its id, so the room removes that
// stroke and no other.
export function undoStroke() {
  if (currentStrokeId) return;
  if (strokeHistory.length === 0) return;

  var stroke = strokeHistory.pop();
  renderCompletedStrokes();
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

  var entry = ensureRemotePathEl(strokeId, color, width);
  if (!entry) return;

  // Joined mid-stroke: start the path at the first point we got.
  if (entry.path === "" && !/^\s*M/.test(delta)) {
    delta = delta.replace(/^\s*L/, "M");
  }

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
