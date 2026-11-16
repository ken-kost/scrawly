// In-game canvas (DrawingCanvas in game_page.ex).
//
// Drawer: pointer input comes from the native stroke engine
// (stroke_engine.mjs), enabled by GamePage through setDrawingEnabled while
// the user is the drawer in :drawing. Finished strokes are committed locally,
// synchronously, into the history ({id, path, color, width, gesture}) and
// appended as one [data-completed] path to the JS-owned
// #game-canvas-drawer-strokes group. Every canvas change (commit, undo by
// stroke id, clear) then goes to the server through a FIFO op queue: only the
// head is in flight (the :send_stroke_op page action) and it is resent until
// the room answers (an ack, a denial or a rejection releases it). Each op
// carries {op_epoch, op_seq} so the room ignores resends (RoomServer stroke
// ops). The stroke's final segments stream to viewers over the game socket as
// ~20 Hz chunks.
//
// Undo takes back a whole gesture: the strokes a long gesture was split into
// share its `gesture` id (stroke_engine.mjs), which only this tab's history
// knows (it never goes to the room). One press removes them all and queues
// one undo op per stroke, each with its own op_seq, like any other op.
// Strokes that came from the room (a reload, a drawer's other tab) have no
// gesture: one per press. A history replaced by a snapshot (a rebase after
// Back/Forward, a rejection) keeps the gestures of the strokes it still holds.
// The toolbar's undo button follows whether the history holds anything
// (GamePage :undo_available, dispatched when that changes).
//
// Viewers: Hologram renders the completed strokes; the live chunks relayed by
// GameChannel are drawn into the #game-canvas-overlay group until the stroke
// arrives through :stroke_completed (removeRemoteOverlay). Ids of finished or
// dropped overlays are remembered (bounded), so a late chunk cannot recreate
// an orphan overlay.
//
// Page instances: the marker (#game-page-marker) carries the instance's
// mount_id (data-mount). mountCanvas(mountId) starts afresh for a new
// instance; restoreCanvas(mountId) takes a Back/Forward restored one back.
// The op queue only sends while the marker in the document is the instance
// it belongs to: leaving the page (a header link, Back) pauses it, and
// restoring that same instance resumes it, so ops queued when the page was
// left are not lost.
//
// The tool a stroke starts with is draw_tools.mjs's (GamePage pushes its
// toolbar's tool there), or the eraser for a gesture pressed with the right
// button or with Ctrl (gestureStroke; the toolbar's tool stays as it is,
// and viewers get an ordinary eraser stroke); mountCanvas resets it, so a
// new page instance never inherits the eraser or colour of an earlier one.
// With the engine come the toolbar's native controls (draw_controls.mjs: the
// size slider, the keyboard shortcuts) and the size ring over the canvas
// (size_ring.mjs, shown while the engine is enabled, in #game-canvas-ring).
//
// The colour picker (eyedropper.mjs) picks from the history: a press that
// picks (the picker, or Alt with the brush or the fill) is the engine's
// takePress and starts no stroke, and the swatch beside the pointer
// (#game-canvas-pick) shows what it would pick.
//
// The fill tool (fill_tool.mjs) is the other takePress: a press with the
// fill selected starts no stroke either; the fill worker works out the area
// from the history and the shape comes back as one more history entry,
// {id, path, color, width: 1, fill: true, gesture: id}, committed like a
// stroke (a [data-completed] path filled evenodd, and a "commit" op with
// `fill: true`), so one undo takes one fill back. Only if the canvas is
// still the one pressed (the same generation, drawing on); fills send no
// live chunks. "too detailed" shows in #game-canvas-notice. The history's paint model (paint_model.mjs,
// "game") keeps its shapes in step with the history: an undo forgets one,
// every replacement of the history goes through setHistory (retain), and
// adding a stroke costs nothing (shapes are made on the first pick).
//
// Hologram 0.12 copies this module into every page bundle that can reach
// GamePage, and each bundle rebinds the page's JS.call names to its own copy.
// So all state lives in one window slot (state()), shared by every copy, and
// the stroke engine is a window singleton too: whichever copy GamePage calls,
// it acts on the same canvas, queue and page generation.

import { createStrokeEngine, startDelta } from "./stroke_engine.mjs";
import { currentTool, gestureStroke, resetDrawTool } from "./draw_tools.mjs";
import { installDrawControls } from "./draw_controls.mjs";
import { ensureSizeRing, refreshSizeRings } from "./size_ring.mjs";
import { paintModel } from "./paint_model.mjs";
import { ensurePickSwatch, pickPress } from "./eyedropper.mjs";
import { ensureFillTool } from "./fill_tool.mjs";

var SVG_NS = "http://www.w3.org/2000/svg";
var SVG_ID = "game-canvas-svg";
var DRAWER_GROUP_ID = "game-canvas-drawer-strokes";
var OVERLAY_ID = "game-canvas-overlay";
var ACTIVE_PATH_ID = "drawing-path";
var RING_ID = "game-canvas-ring";
var PICK_ID = "game-canvas-pick";
var NOTICE_ID = "game-canvas-notice";
var MARKER_ID = "game-page-marker";
var STATE_SLOT = "__scrawlyGameCanvas";
var ENGINE_SLOT = "__scrawlyGameStrokeEngine";

// For a stroke that comes without a colour or a width.
var DEFAULT_COLOR = "#000000";
var DEFAULT_WIDTH = 2;

var FLUSH_INTERVAL_MS = 50;
// StrokeRules.valid_delta? caps a chunk's delta at 2_000 bytes.
var MAX_CHUNK = 1500;

// An unanswered op is resent after OP_RETRY_MS, and after OP_SLOW_AFTER
// attempts every OP_SLOW_RETRY_MS: ops are idempotent, so a resend is never
// harmful, and dropping one would leave the drawer's canvas ahead of the
// room for good.
var OP_RETRY_MS = 5000;
var OP_SLOW_AFTER = 3;
var OP_SLOW_RETRY_MS = 15000;

var MAX_CLOSED_IDS = 1000;

function randomToken() {
  if (globalThis.crypto && globalThis.crypto.randomUUID) return globalThis.crypto.randomUUID();
  return Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 12);
}

function freshState() {
  return {
    // Prefixes the stroke ids made in this document (ownStroke).
    docToken: Math.random().toString(36).slice(2, 10),
    enabled: false,
    history: [],
    idCounter: 0,
    // Chunk stream of the stroke being drawn (the engine holds its path).
    live: { id: null, color: DEFAULT_COLOR, width: DEFAULT_WIDTH, seq: 0, delta: "" },
    flushTimer: null,
    opEpoch: randomToken(),
    opSeq: 0,
    queue: [],
    opTimer: null,
    // The page instance (GamePage mount_id) the canvas and queue belong to.
    mountKey: null,
    // What GamePage was last told about undo (:undo_available).
    undoReported: false,
    // Bumped by every mount and restore; game_channel.mjs uses it to tell a
    // stale channel (from an earlier page instance) from the current one.
    generation: 0,
    // Bumped by every clear (a turn's reset, the drawer's, another tab's): a
    // fill worked out before one is dropped (commitFill).
    clears: 0,
    remote: {},
    closed: new Set()
  };
}

function state() {
  var s = window[STATE_SLOT];
  if (!s) {
    s = freshState();
    window[STATE_SLOT] = s;
  }
  return s;
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
  return state().generation;
}

// The game page in the document is the instance the canvas belongs to.
function pageIsMine() {
  var marker = document.getElementById(MARKER_ID);
  if (!marker) return false;
  var key = state().mountKey;
  if (key === null || key === undefined) return true;
  return marker.getAttribute("data-mount") === String(key);
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

// A fill: its inside in its colour, no outline (StrokeRules fills).
function makeFillPath(d, color) {
  var p = document.createElementNS(SVG_NS, "path");
  p.setAttribute("d", d);
  p.setAttribute("fill", color);
  p.setAttribute("fill-rule", "evenodd");
  p.setAttribute("stroke", "none");
  return p;
}

function makeStrokeNode(s) {
  var p = s.fill === true ? makeFillPath(s.path, s.color) : makePath(s.path, s.color, s.width);
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
  var history = state().history;
  var frag = document.createDocumentFragment();
  for (var i = 0; i < history.length; i++) frag.appendChild(makeStrokeNode(history[i]));
  group.replaceChildren(frag);
}

// A fill keeps `fill: true` (and width 1); a line has no such key.
function normalizeStroke(s) {
  var n = {
    id: s.id,
    path: s.path || "",
    color: s.color || DEFAULT_COLOR,
    width: s.width || DEFAULT_WIDTH
  };
  if (s.fill === true) {
    n.fill = true;
    n.width = 1;
  }
  return n;
}

// The history's paint model (the colour picker's): its shapes go with the
// strokes, and all of them once the canvas has left the document.
function paint() {
  return paintModel("game", {
    present: function () {
      return document.getElementById(SVG_ID) !== null;
    }
  });
}

// Every replacement of the history: the paint model keeps the shapes of
// the strokes still in it, and the strokes still in it keep their gesture.
function setHistory(list) {
  var s = state();
  var gestures = null;
  for (var i = 0; i < s.history.length; i++) {
    var old = s.history[i];
    if (old.gesture) (gestures = gestures || {})[old.id] = old.gesture;
  }
  if (gestures) {
    for (var j = 0; j < list.length; j++) {
      if (!list[j].gesture && gestures[list[j].id]) list[j].gesture = gestures[list[j].id];
    }
  }
  s.history = list;
  paint().retain(list);
  reportUndo();
}

// The ids of the strokes an undo takes back, newest first: the newest
// stroke's gesture (every stroke of the history with its gesture id), or
// that stroke alone when it has none. Pure.
export function lastGesture(history) {
  var n = history ? history.length : 0;
  if (n === 0) return [];
  var last = history[n - 1];
  if (!last.gesture) return [last.id];
  var ids = [];
  for (var i = n - 1; i >= 0; i--) {
    if (history[i].gesture === last.gesture) ids.push(history[i].id);
  }
  return ids;
}

// GamePage's undo button: told when the history becomes empty or not, and
// only while its own page instance is in the document.
function reportUndo() {
  var s = state();
  var available = s.history.length > 0;
  if (available === s.undoReported) return;
  if (!globalThis.Hologram || !pageIsMine()) return;
  s.undoReported = available;
  globalThis.Hologram.dispatchAction("undo_available", "page", { available: available });
}

function colorInHistory(x, y) {
  return paint().colorAt(state().history, x, y);
}

function historyIndex(id) {
  var history = state().history;
  for (var i = history.length - 1; i >= 0; i--) {
    if (history[i].id === id) return i;
  }
  return -1;
}

function makeStrokeId() {
  var s = state();
  s.idCounter += 1;
  return "s-" + s.docToken + "-" + Date.now().toString(36) + "-" + s.idCounter;
}

// Drawn in this document (this tab), as opposed to another tab of the same
// drawer.
function ownStroke(id) {
  return typeof id === "string" && id.indexOf("s-" + state().docToken + "-") === 0;
}

// ---------------------------------------------------------------------------
// Stroke engine (drawer)

function ensureEngine() {
  var engine = window[ENGINE_SLOT];
  if (engine && !engine.isDisposed()) return engine;

  var pick = pickPress(function (_ctx, x, y) {
    return colorInHistory(x, y);
  });
  var fill = ensureFillTool("game", {
    svgId: SVG_ID,
    noticeId: NOTICE_ID,
    strokes: function () {
      return state().history;
    },
    colorAt: function (_ctx, x, y) {
      return colorInHistory(x, y);
    },
    // The canvas as pressed: a fill that comes back after a new page
    // instance, a clear (a new turn's too) or the end of drawing is dropped.
    begin: function () {
      var s = state();
      return s.enabled && gamePagePresent() ? { generation: s.generation, clears: s.clears } : null;
    },
    commit: commitFill
  });

  engine = createStrokeEngine({
    svgId: SVG_ID,
    activePathId: ACTIVE_PATH_ID,
    canStart: function () {
      return gamePagePresent() && getDrawerGroup() !== null;
    },
    // A press that picks a colour (eyedropper.mjs) or fills an area
    // (fill_tool.mjs) draws no stroke.
    takePress: function (ctx, press, point) {
      return pick(ctx, press, point) || fill(ctx, press, point);
    },
    // The press can make this one gesture erase (the right button, Ctrl).
    getTool: function (_ctx, press) {
      return gestureStroke(currentTool(), press);
    },
    newStrokeId: makeStrokeId,
    onStart: beginStroke,
    onSegments: queueSegments,
    onEnd: commitStroke
  });
  engine.setEnabled(state().enabled);
  window[ENGINE_SLOT] = engine;
  installDrawControls();
  ensureSizeRing(SVG_ID, RING_ID);
  ensurePickSwatch(SVG_ID, PICK_ID, colorInHistory);
  return engine;
}

// GamePage: on :mounted, after a restore, and whenever is_drawer or the phase
// changes (the rule is GamePage.can_draw?/1). Disabling drops a stroke in
// progress without committing it.
export function setDrawingEnabled(enabled) {
  var s = state();
  s.enabled = !!enabled;
  if (!s.enabled) resetStrokeInProgress();
  ensureEngine().setEnabled(s.enabled);
  refreshSizeRings();
}

// ---------------------------------------------------------------------------
// Stroke in progress (drawer)

function scheduleFlush() {
  var s = state();
  if (s.flushTimer) return;
  s.flushTimer = setTimeout(function () {
    state().flushTimer = null;
    flushPending();
  }, FLUSH_INTERVAL_MS);
}

function stopFlushTimer() {
  var s = state();
  if (s.flushTimer) {
    clearTimeout(s.flushTimer);
    s.flushTimer = null;
  }
}

function flushPending() {
  var live = state().live;
  if (!live.id || !live.delta) return;
  var gs = window.gameSocket;
  if (gs && gs.isInRoom && gs.isInRoom() && gs.sendDrawingStrokeChunk) {
    live.seq += 1;
    gs.sendDrawingStrokeChunk(live.id, live.seq, live.delta, live.color, live.width);
  }
  live.delta = "";
}

// Drops the stroke in progress: the engine's gesture, its chunk stream and
// the active path.
function resetStrokeInProgress() {
  var engine = window[ENGINE_SLOT];
  if (engine) engine.cancel();
  stopFlushTimer();
  var live = state().live;
  live.id = null;
  live.seq = 0;
  live.delta = "";
  var el = getPathEl();
  if (el) el.setAttribute("d", "");
}

function beginStroke(stroke) {
  stopFlushTimer();
  var live = state().live;
  live.id = stroke.id;
  live.color = stroke.color;
  live.width = stroke.width;
  live.seq = 0;
  live.delta = stroke.delta;
  // Leading-edge flush so viewers see the first point at once.
  flushPending();
}

function queueSegments(stroke) {
  var live = state().live;
  if (stroke.id !== live.id) return;
  live.delta += stroke.delta;
  if (live.delta.length >= MAX_CHUNK) {
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
  var live = state().live;
  if (stroke.id === live.id) flushPending();
  live.id = null;
  live.seq = 0;
  live.delta = "";
  if (!stroke.id || !stroke.path) return;

  var s = { id: stroke.id, path: stroke.path, color: stroke.color, width: stroke.width };
  if (stroke.gesture) s.gesture = stroke.gesture;
  state().history.push(s);
  appendStrokeNode(s);
  reportUndo();

  enqueueOp("commit", {
    stroke_id: s.id,
    path: s.path,
    color: s.color,
    width: s.width
  });
}

// The fill tool's shape (fill_tool.mjs), for the canvas `token` names:
// committed like a stroke, as one gesture of its own.
function commitFill(token, path, color) {
  var s = state();
  if (!token || token.generation !== s.generation || token.clears !== s.clears) return;
  if (!s.enabled || !gamePagePresent()) return;
  if (typeof path !== "string" || path === "") return;
  var id = makeStrokeId();
  var f = { id: id, path: path, color: color, width: 1, fill: true, gesture: id };
  s.history.push(f);
  appendStrokeNode(f);
  reportUndo();
  enqueueOp("commit", { stroke_id: id, path: path, color: color, width: 1, fill: true });
}

// ---------------------------------------------------------------------------
// Op queue (drawer)

function clearOpTimer() {
  var s = state();
  if (s.opTimer) {
    clearTimeout(s.opTimer);
    s.opTimer = null;
  }
}

function resetOpQueue() {
  clearOpTimer();
  state().queue = [];
}

function enqueueOp(kind, fields) {
  var s = state();
  s.opSeq += 1;
  var op = { op_epoch: s.opEpoch, op_seq: s.opSeq, kind: kind };
  for (var k in fields) op[k] = fields[k];
  s.queue.push({ op: op, attempts: 0 });
  if (s.queue.length === 1) sendHead();
}

// Sends (or resends) the head. Pauses, keeping the queue, while the page in
// the document is not the instance the queue belongs to: its ops must not
// reach another page's actions (restoreCanvas resumes, mountCanvas drops).
function sendHead() {
  clearOpTimer();
  var s = state();
  if (!globalThis.Hologram || !pageIsMine()) return;

  var head = s.queue[0];
  if (!head) return;

  head.attempts += 1;
  if (head.attempts === OP_SLOW_AFTER + 1) {
    console.warn("stroke op not acknowledged yet, still retrying", head.op.kind, head.op.op_seq);
  }
  globalThis.Hologram.dispatchAction("send_stroke_op", "page", head.op);
  s.opTimer = setTimeout(sendHead, head.attempts < OP_SLOW_AFTER ? OP_RETRY_MS : OP_SLOW_RETRY_MS);
}

// Releases the head when `seq` is its op_seq. A reply without a seq can't
// be matched to an op, so it releases nothing (it could be a late reply to
// an op released long ago).
function releaseHead(seq) {
  if (seq === null || seq === undefined) return false;
  var head = state().queue[0];
  if (!head || head.op.op_seq !== seq) return false;
  state().queue.shift();
  sendHead();
  return true;
}

// :stroke_op_acked (applied, or ignored as a duplicate): send the next op.
export function ackStrokeOp(seq) {
  releaseHead(seq);
}

// :command_denied for a stroke op: drop it and continue.
export function rejectStrokeOp(seq) {
  releaseHead(seq);
}

// :stroke_rejected (invalid stroke or full canvas): show what the room holds.
// setStrokes also drops the queued ops, whose strokes leave the canvas too. A
// rejection of an op that is not the head (any more) is stale and ignored.
// Returns whether it was applied.
export function applyRejectedStrokes(seq, strokes) {
  var head = state().queue[0];
  if (seq === null || seq === undefined || !head || head.op.op_seq !== seq) return false;
  setStrokes(strokes);
  return true;
}

// The room's strokes with the queued ops (not applied by the room yet, as
// far as this tab knows) applied on top: what the room will hold once they
// are. An op the room did apply changes nothing here (a commit's stroke is
// already in the list, an undone one already gone).
function rebase(roomStrokes, queue) {
  var list = (roomStrokes || [])
    .filter(function (s) { return s && s.id; })
    .map(normalizeStroke);

  for (var i = 0; i < queue.length; i++) {
    var op = queue[i].op;
    if (op.kind === "commit") {
      if (!list.some(function (s) { return s.id === op.stroke_id; })) {
        list.push(normalizeStroke({ id: op.stroke_id, path: op.path, color: op.color, width: op.width, fill: op.fill }));
      }
    } else if (op.kind === "undo") {
      list = list.filter(function (s) { return s.id !== op.stroke_id; });
    } else if (op.kind === "clear") {
      list = [];
    }
  }

  return list;
}

// ---------------------------------------------------------------------------
// Page instances and canvas resets

function resetDrawingState() {
  state().clears += 1;
  resetStrokeInProgress();
  resetOpQueue();
  setHistory([]);
  clearRemoteOverlay();
}

// GamePage :mounted (a fresh page instance, `mountKey` its mount_id): drops
// what an earlier instance left (history, queue, overlays, the tool it was
// using). Drawing stays off and the tool at its default until :mounted's
// setDrawingEnabled and setDrawTool.
export function mountCanvas(mountKey) {
  var s = state();
  s.generation += 1;
  s.enabled = false;
  // A new instance's state starts with undo off (GamePage init).
  s.undoReported = false;
  resetDrawingState();
  resetDrawTool();
  s.mountKey = mountKey === undefined ? null : mountKey;
  ensureEngine().setEnabled(false);
}

// GamePage :mounted, drawer only: the room's strokes at page load go in front
// of anything drawn locally since, so they show at once and can be undone.
export function restoreStrokes(strokes) {
  ensureEngine();
  var s = state();
  var local = {};
  for (var i = 0; i < s.history.length; i++) local[s.history[i].id] = true;

  var restored = (strokes || [])
    .filter(function (st) { return st && st.id && !local[st.id]; })
    .map(normalizeStroke);

  setHistory(restored.concat(s.history));
  renderCompletedStrokes();
}

// A page instance restored by Back/Forward (GamePage :page_shown, the
// second time). Its re-render dropped the JS-drawn paths. The same instance
// as before gets its local canvas back at once and its queued ops are sent
// again; another instance starts empty (the old instance's queue is
// dropped). Drawing is off until the resync's reply (setDrawingEnabled),
// which also brings the room's strokes for a drawer (rebaseCanvas).
export function restoreCanvas(mountKey) {
  ensureEngine();
  var s = state();
  s.generation += 1;
  s.enabled = false;
  // GamePage's restore turns undo off; the history below tells it again.
  s.undoReported = false;
  resetStrokeInProgress();
  ensureEngine().setEnabled(false);
  dropRemoteOverlays();

  var same = s.mountKey !== null && mountKey !== null && mountKey !== undefined &&
    String(s.mountKey) === String(mountKey);

  if (!same) {
    resetOpQueue();
    setHistory([]);
  }

  s.mountKey = mountKey === undefined ? null : mountKey;
  renderCompletedStrokes();
  reportUndo();
  if (same) sendHead();
}

// The drawer's canvas from a room snapshot (the resync after a restore):
// the room's strokes plus the ops still queued here, so it shows what the
// room will hold once they are applied.
export function rebaseCanvas(strokes) {
  setHistory(rebase(strokes, state().queue));
  renderCompletedStrokes();
}

// The drawer's own clear: queued ops still go out first, then the clear.
export function clearDrawing() {
  state().clears += 1;
  resetStrokeInProgress();
  setHistory([]);
  clearRemoteOverlay();
  renderCompletedStrokes();
  enqueueOp("clear", {});
}

// The room's strokes after a rejection: replaces the canvas and drops the
// stroke in progress and the op queue.
export function setStrokes(strokes) {
  resetStrokeInProgress();
  resetOpQueue();
  setHistory((strokes || []).map(normalizeStroke));
  clearRemoteOverlay();
  renderCompletedStrokes();
}

// New game or turn (every page): an empty canvas, nothing in flight.
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

// Undo takes back the newest gesture (lastGesture) and sends one undo op
// per stroke, newest first, so the room removes those strokes and no
// other. Ignored while a stroke is being drawn.
export function undoStroke() {
  var engine = window[ENGINE_SLOT];
  if (engine && engine.isDrawing()) return;
  var history = state().history;
  var ids = lastGesture(history);
  if (ids.length === 0) return;

  for (var i = 0; i < ids.length; i++) {
    var at = historyIndex(ids[i]);
    if (at >= 0) history.splice(at, 1);
    paint().forget(ids[i]);
    removeStrokeNode(ids[i]);
    enqueueOp("undo", { stroke_id: ids[i] });
  }
  reportUndo();
}

// ---------------------------------------------------------------------------
// The room's canvas broadcasts on a drawer's tab. Only another tab of the
// same drawer changes anything: this tab's own changes are already on its
// canvas.

// :stroke_completed: a stroke drawn in another tab joins this tab's canvas
// (and its live overlay goes).
export function adoptStroke(stroke) {
  if (!stroke || !stroke.id) return;
  removeRemoteOverlay(stroke.id);
  if (ownStroke(stroke.id) || historyIndex(stroke.id) >= 0) return;
  var s = normalizeStroke(stroke);
  state().history.push(s);
  appendStrokeNode(s);
  reportUndo();
}

// :drawing_undone: a stroke another tab undid leaves this one too.
export function forgetStroke(strokeId) {
  var i = historyIndex(strokeId);
  if (i < 0) return;
  state().history.splice(i, 1);
  paint().forget(strokeId);
  removeStrokeNode(strokeId);
  reportUndo();
}

// :drawing_cleared, with the epoch of the tab that cleared: another tab's
// clear empties this canvas too, except the strokes still queued here (the
// room stores them after the clear).
export function applyRoomClear(opEpoch) {
  var s = state();
  if (opEpoch && opEpoch === s.opEpoch) return;
  s.clears += 1;
  setHistory(rebase([], s.queue.filter(function (entry) { return entry.op.kind === "commit"; })));
  dropRemoteOverlays();
  renderCompletedStrokes();
}

// ---------------------------------------------------------------------------
// Live overlays (viewers, and a drawer's other tabs)

function closeStrokeId(strokeId) {
  if (!strokeId) return;
  var closed = state().closed;
  closed.delete(strokeId);
  closed.add(strokeId);
  if (closed.size > MAX_CLOSED_IDS) {
    closed.delete(closed.values().next().value);
  }
}

function removeOverlayEntry(strokeId) {
  var remote = state().remote;
  var entry = remote[strokeId];
  if (!entry) return;
  if (entry.pathEl && entry.pathEl.parentNode) {
    entry.pathEl.parentNode.removeChild(entry.pathEl);
  }
  delete remote[strokeId];
}

function ensureRemotePathEl(strokeId, color, width) {
  var remote = state().remote;
  var entry = remote[strokeId];
  if (entry && entry.pathEl && entry.pathEl.isConnected) return entry;

  var overlay = getOverlay();
  if (!overlay) return null;

  if (!entry) {
    entry = { pathEl: null, path: "", lastSeq: 0, color: color || DEFAULT_COLOR, width: width || DEFAULT_WIDTH };
    remote[strokeId] = entry;
  }

  // A re-rendered svg dropped the old element: redraw what we already have.
  entry.pathEl = makePath(entry.path, entry.color, entry.width);
  entry.pathEl.setAttribute("data-remote-in-progress", strokeId);
  overlay.appendChild(entry.pathEl);
  return entry;
}

export function applyRemoteChunk(strokeId, seq, delta, color, width) {
  if (!strokeId || !delta) return;
  if (state().closed.has(strokeId)) return;

  var known = state().remote[strokeId];
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

// A viewer's snapshot (:room_resynced): the overlays of strokes it holds are
// done; the others are strokes still being drawn, whose live preview stays.
export function settleRemoteStrokes(strokeIds) {
  (strokeIds || []).forEach(function (id) {
    if (state().remote[id]) removeRemoteOverlay(id);
  });
}

// A viewer's :drawing_cleared. The clear cancelled the drawer's stroke in
// progress, so its overlay goes, but a stroke the drawer started after the
// clear (its chunks are faster than the clear's broadcast) must come back:
// the ids are not closed, so its next chunk redraws it from there.
export function clearRemoteStrokes() {
  dropRemoteOverlays();
}

// Removes every overlay, ids not closed.
function dropRemoteOverlays() {
  Object.keys(state().remote).forEach(removeOverlayEntry);
  state().remote = {};
}

// Removes every overlay and closes the ids: their strokes are over (turn
// reset, end of the drawing phase).
function clearRemoteOverlay() {
  Object.keys(state().remote).forEach(function (sid) {
    closeStrokeId(sid);
    removeOverlayEntry(sid);
  });
  state().remote = {};
}
