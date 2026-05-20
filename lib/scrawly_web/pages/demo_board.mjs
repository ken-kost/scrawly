// Bridge between the shared demo canvas SVG and the DemoBoard Phoenix channel.
// Keeps drawing smooth by mutating SVG paths directly — Hologram only ever sees
// the full strokes list on snapshot, never per-pixel state.
//
// Strokes are also streamed live to other viewers as ~20Hz delta chunks while
// the user is still drawing; the canonical completed stroke is sent on
// pointer_up. Other clients render in-progress strokes via JS-injected SVG
// path overlays keyed by `stroke_id`.

var socket = null;
var channel = null;
var strokes = [];        // completed strokes from the server [{path, color, width}]
var currentColor = "#000000";
var currentWidth = 2;
var currentEraser = false;
var activePath = "";
var leaveListenerBound = false;

// Drawer-side chunk-streaming state
var strokeIdCounter = 0;
var currentStrokeId = null;
var currentStrokeColor = "#000000";
var currentStrokeWidth = 2;
var currentSeq = 0;
var pendingDelta = "";
var flushTimer = null;
var FLUSH_INTERVAL_MS = 50;

// Live overlays for other drawers' in-progress strokes
// { [strokeId]: { pathEl, path, color, width } }
var remoteInProgress = {};

const SVG_ID = "demo-board-svg";
const ACTIVE_PATH_ID = "demo-board-active-path";
const ERASER_COLOR = "#ffffff";
const ERASER_WIDTH = 18;

function svg() {
  return document.getElementById(SVG_ID);
}

function activePathEl() {
  return document.getElementById(ACTIVE_PATH_ID);
}

// Convert screen-pixel offset_x/offset_y (relative to the SVG element) into
// viewBox coordinates so the path tracks the cursor exactly regardless of
// the rendered canvas size.
function toViewBox(x, y) {
  var el = svg();
  if (!el) return [x, y];
  var vb = el.viewBox && el.viewBox.baseVal;
  if (!vb || !el.clientWidth || !el.clientHeight) return [x, y];
  var scaleX = vb.width / el.clientWidth;
  var scaleY = vb.height / el.clientHeight;
  return [Math.round((x * scaleX + Number.EPSILON) * 10) / 10,
          Math.round((y * scaleY + Number.EPSILON) * 10) / 10];
}

function setActivePathD(d, color, width) {
  var el = activePathEl();
  if (el) {
    el.setAttribute("d", d);
    el.setAttribute("stroke", color);
    el.setAttribute("stroke-width", width);
  }
}

function renderStrokes() {
  var s = svg();
  if (!s) return;

  var old = s.querySelectorAll("[data-demo-stroke]");
  for (var i = 0; i < old.length; i++) old[i].remove();

  var ap = activePathEl();
  for (var j = 0; j < strokes.length; j++) {
    var st = strokes[j];
    var p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", st.path);
    p.setAttribute("stroke", st.color);
    p.setAttribute("stroke-width", st.width);
    p.setAttribute("fill", "none");
    p.setAttribute("stroke-linecap", "round");
    p.setAttribute("stroke-linejoin", "round");
    p.setAttribute("data-demo-stroke", "true");
    if (ap) s.insertBefore(p, ap);
    else s.appendChild(p);
  }
}

// ── Remote-in-progress overlay (other drawers' live strokes) ─────────

function ensureRemotePathEl(strokeId, color, width) {
  var entry = remoteInProgress[strokeId];
  if (entry && entry.pathEl && entry.pathEl.isConnected) return entry;

  var s = svg();
  if (!s) return null;

  var p = document.createElementNS("http://www.w3.org/2000/svg", "path");
  p.setAttribute("d", "");
  p.setAttribute("stroke", color || "#000000");
  p.setAttribute("stroke-width", width || 2);
  p.setAttribute("fill", "none");
  p.setAttribute("stroke-linecap", "round");
  p.setAttribute("stroke-linejoin", "round");
  p.setAttribute("data-remote-in-progress", strokeId);

  var ap = activePathEl();
  if (ap) s.insertBefore(p, ap);
  else s.appendChild(p);

  entry = { pathEl: p, path: "", color: color || "#000000", width: width || 2 };
  remoteInProgress[strokeId] = entry;
  return entry;
}

function applyRemoteChunk(strokeId, delta, color, width) {
  if (!strokeId || !delta) return;
  var entry = ensureRemotePathEl(strokeId, color, width);
  if (!entry) return;
  entry.path += delta;
  entry.color = color || entry.color;
  entry.width = width || entry.width;
  entry.pathEl.setAttribute("d", entry.path);
  entry.pathEl.setAttribute("stroke", entry.color);
  entry.pathEl.setAttribute("stroke-width", entry.width);
}

function removeRemoteOverlay(strokeId) {
  var entry = remoteInProgress[strokeId];
  if (!entry) return;
  if (entry.pathEl && entry.pathEl.parentNode) {
    entry.pathEl.parentNode.removeChild(entry.pathEl);
  }
  delete remoteInProgress[strokeId];
}

function abandonRemoteStroke(strokeId) {
  var entry = remoteInProgress[strokeId];
  if (!entry) return;
  if (entry.pathEl && entry.pathEl.parentNode) {
    entry.pathEl.parentNode.removeChild(entry.pathEl);
  }
  delete remoteInProgress[strokeId];
}

function clearRemoteOverlay() {
  Object.keys(remoteInProgress).forEach(function (sid) {
    var entry = remoteInProgress[sid];
    if (entry && entry.pathEl && entry.pathEl.parentNode) {
      entry.pathEl.parentNode.removeChild(entry.pathEl);
    }
  });
  remoteInProgress = {};
}

// ── Drawer-side streaming helpers ────────────────────────────────────

function makeStrokeId() {
  strokeIdCounter += 1;
  return "d-" + Date.now() + "-" + strokeIdCounter;
}

function scheduleFlush() {
  if (flushTimer) return;
  flushTimer = setTimeout(function () {
    flushTimer = null;
    flushPending();
  }, FLUSH_INTERVAL_MS);
}

function flushPending() {
  if (!channel || !currentStrokeId || !pendingDelta) return;
  currentSeq += 1;
  channel.push("stroke_chunk", {
    stroke_id: currentStrokeId,
    seq: currentSeq,
    delta: pendingDelta,
    color: currentStrokeColor,
    width: currentStrokeWidth
  });
  pendingDelta = "";
}

// ── Public API ───────────────────────────────────────────────────────

export function connectDemoBoard() {
  if (channel) return;
  if (!window.Phoenix || !window.Phoenix.Socket) {
    console.error("Phoenix.Socket not available for demo board");
    return;
  }

  socket = new window.Phoenix.Socket("/socket", { params: { demo: "true" } });
  socket.connect();

  channel = socket.channel("demo:board", {});
  channel.on("strokes", function(payload) {
    strokes = (payload.strokes || []).map(function(s) {
      return { path: s.path || "", color: s.color || "#000000", width: s.width || 2 };
    });
    clearRemoteOverlay();
    renderStrokes();
  });
  channel.on("stroke", function(stroke) {
    // If this stroke was streamed via chunks, remove the overlay before the
    // canonical path is added to `strokes` — gapless handoff, no flicker.
    if (stroke.stroke_id) removeRemoteOverlay(stroke.stroke_id);
    strokes.push({ path: stroke.path, color: stroke.color, width: stroke.width });
    renderStrokes();
  });
  channel.on("stroke_chunk", function(payload) {
    applyRemoteChunk(payload.stroke_id, payload.delta, payload.color, payload.width);
  });
  channel.on("stroke_abandon", function(payload) {
    abandonRemoteStroke(payload.stroke_id);
  });
  channel.on("cleared", function() {
    strokes = [];
    clearRemoteOverlay();
    renderStrokes();
    setActivePathD("", currentColor, currentWidth);
    activePath = "";
  });
  channel.join().receive("error", function(resp) {
    console.error("Failed to join demo:board channel:", resp);
    channel = null;
  });

  bindLeaveListener();
}

// Pointer events don't fire on the SVG once the cursor exits its bounds,
// so without this the active stroke would silently keep its in-progress
// state and resume drawing when the cursor re-entered. End the stroke as
// soon as the pointer leaves the canvas.
function bindLeaveListener() {
  if (leaveListenerBound) return;
  var el = svg();
  if (!el) return;
  el.addEventListener("pointerleave", function() { endStroke(); });
  leaveListenerBound = true;
}

export function disconnectDemoBoard() {
  if (channel) { channel.leave(); channel = null; }
  if (socket) { socket.disconnect(); socket = null; }
  strokes = [];
  clearRemoteOverlay();
}

export function startStroke(x, y) {
  var p = toViewBox(x, y);
  activePath = "M " + p[0] + " " + p[1];
  var c = currentEraser ? ERASER_COLOR : currentColor;
  var w = currentEraser ? ERASER_WIDTH : currentWidth;
  setActivePathD(activePath, c, w);

  // Begin a new streamed stroke
  currentStrokeId = makeStrokeId();
  currentStrokeColor = c;
  currentStrokeWidth = w;
  currentSeq = 0;
  pendingDelta = activePath;
  // Leading-edge flush so peers see the first point within ~1 RTT, not 50ms+RTT
  flushPending();
}

export function continueStroke(x, y) {
  if (!activePath) return;
  var p = toViewBox(x, y);
  var delta = " L " + p[0] + " " + p[1];
  activePath += delta;
  pendingDelta += delta;
  var c = currentEraser ? ERASER_COLOR : currentColor;
  var w = currentEraser ? ERASER_WIDTH : currentWidth;
  setActivePathD(activePath, c, w);
  scheduleFlush();
}

export function endStroke() {
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  if (!activePath) {
    currentStrokeId = null;
    pendingDelta = "";
    return;
  }
  // Flush remaining chunks first so peers' overlays are caught up before completion.
  flushPending();

  var c = currentStrokeColor;
  var w = currentStrokeWidth;

  if (activePath.length > 5 && channel && currentStrokeId) {
    channel.push("stroke_complete", {
      stroke_id: currentStrokeId,
      path: activePath,
      color: c,
      width: w
    });
  } else if (activePath.length > 5 && channel) {
    // Fallback to legacy single-shot if streaming wasn't initialised
    channel.push("draw", { path: activePath, color: c, width: w });
  }

  activePath = "";
  currentStrokeId = null;
  pendingDelta = "";
  setActivePathD("", c, w);
}

export function clearBoard() {
  if (channel) channel.push("clear", {});
}

export function setColor(color) {
  currentColor = color;
  currentEraser = false;
}

export function setWidth(width) {
  currentWidth = width;
  currentEraser = false;
}

export function setEraser() {
  currentEraser = true;
}
