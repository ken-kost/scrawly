// JS-managed SVG drawing — bypasses Hologram re-renders for smooth drawing.
// Supports color, width, stroke history, undo, and live streaming of in-flight
// strokes via delta chunks (~20Hz throttled) to other viewers.

var currentColor = "#000000";
var currentWidth = 2;
var strokeHistory = []; // completed strokes: [{path, color, width}, ...]
var currentStrokePath = ""; // path being drawn right now

// Chunk-streaming state for the drawer
var strokeIdCounter = 0;
var currentStrokeId = null;
var currentSeq = 0;
var pendingDelta = "";
var flushTimer = null;
var FLUSH_INTERVAL_MS = 50;

// Remote in-progress strokes from other drawers, keyed by stroke_id.
// { [strokeId]: { pathEl, path, color, width } }
var remoteInProgress = {};

function getPathEl() {
  return document.getElementById("drawing-path");
}

function getSvg() {
  var el = getPathEl();
  return el ? el.closest("svg") : null;
}

function setActivePathD(d) {
  var el = getPathEl();
  if (el) {
    el.setAttribute("d", d);
    el.setAttribute("stroke", currentColor);
    el.setAttribute("stroke-width", currentWidth);
  }
}

function renderCompletedStrokes() {
  // Render completed strokes as separate path elements in the SVG
  var svg = getPathEl() ? getPathEl().closest("svg") : null;
  if (!svg) return;

  // Remove old completed stroke elements (marked with data-completed)
  var old = svg.querySelectorAll("[data-completed]");
  for (var i = 0; i < old.length; i++) {
    old[i].remove();
  }

  // Insert completed strokes before the active path element
  var activePath = getPathEl();
  for (var j = 0; j < strokeHistory.length; j++) {
    var s = strokeHistory[j];
    var p = document.createElementNS("http://www.w3.org/2000/svg", "path");
    p.setAttribute("d", s.path);
    p.setAttribute("stroke", s.color);
    p.setAttribute("stroke-width", s.width);
    p.setAttribute("fill", "none");
    p.setAttribute("stroke-linecap", "round");
    p.setAttribute("stroke-linejoin", "round");
    p.setAttribute("data-completed", "true");
    if (activePath) {
      svg.insertBefore(p, activePath);
    } else {
      svg.appendChild(p);
    }
  }
}

// ── Drawer-side streaming helpers ────────────────────────────────────

function makeStrokeId() {
  strokeIdCounter += 1;
  return "s-" + Date.now() + "-" + strokeIdCounter;
}

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

// Called on pointer_down — begin a new stroke
export function startStroke(x, y) {
  currentStrokePath = "M " + x + " " + y;
  currentStrokeId = makeStrokeId();
  currentSeq = 0;
  pendingDelta = currentStrokePath;
  setActivePathD(currentStrokePath);
  // Leading-edge flush so peers see the first point within ~1 RTT, not 50ms+RTT
  flushPending();
}

// Called on pointer_move — extend the current stroke
export function continueStroke(x, y) {
  var delta = " L " + x + " " + y;
  currentStrokePath += delta;
  pendingDelta += delta;
  setActivePathD(currentStrokePath);
  scheduleFlush();
}

// Called on pointer_up — complete the stroke, send to server, return path
export function endStroke() {
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  // Flush remaining chunks before the completion event
  flushPending();

  if (currentStrokePath) {
    var stroke = { path: currentStrokePath, color: currentColor, width: currentWidth };
    strokeHistory.push(stroke);

    var gs = window.gameSocket;
    if (gs && gs.isInRoom && gs.isInRoom()) {
      if (gs.sendDrawingStrokeComplete && currentStrokeId) {
        gs.sendDrawingStrokeComplete(currentStrokeId, currentStrokePath, currentColor, currentWidth);
      } else if (gs.sendDrawingStroke) {
        // Legacy fallback if streaming senders aren't available
        gs.sendDrawingStroke(currentStrokePath, currentColor, currentWidth);
      } else if (gs.sendDrawingSegment) {
        gs.sendDrawingSegment(currentStrokePath);
      }
    }

    renderCompletedStrokes();
    currentStrokePath = "";
    currentStrokeId = null;
    setActivePathD("");
  }
  return currentStrokePath;
}

// Called on clear
export function clearDrawing() {
  strokeHistory = [];
  currentStrokePath = "";
  setActivePathD("");
  clearRemoteOverlay();
  renderCompletedStrokes();
  var gs = window.gameSocket;
  if (gs && gs.isInRoom()) {
    gs.sendDrawingClear();
  }
}

// Set strokes from server (late joiner sync, undo sync)
export function setStrokes(strokes) {
  strokeHistory = (strokes || []).map(function(s) {
    return { path: s.path || "", color: s.color || "#000000", width: s.width || 2 };
  });
  currentStrokePath = "";
  clearRemoteOverlay();
  renderCompletedStrokes();
  setActivePathD("");
}

// Set the full path (legacy compat / non-drawer sync)
export function setDrawingPath(path) {
  if (!path || path === "") {
    strokeHistory = [];
    currentStrokePath = "";
    clearRemoteOverlay();
    renderCompletedStrokes();
    setActivePathD("");
  }
}

// Return current path string (legacy compat)
export function getDrawingPath() {
  var parts = strokeHistory.map(function(s) { return s.path; });
  if (currentStrokePath) parts.push(currentStrokePath);
  return parts.join(" ");
}

// Reset sent tracking (legacy compat)
export function resetSentLength() {
  // No longer needed with stroke-based model
}

// Tool state setters — called from Hologram actions
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

// Undo last stroke — removes from history, sends undo to server
export function undoStroke() {
  // Don't allow undoing while a stroke is still in-flight — the
  // drawing_stroke_complete event for it hasn't been sent yet.
  if (currentStrokeId) return;
  if (strokeHistory.length > 0) {
    strokeHistory.pop();
    renderCompletedStrokes();
    currentStrokePath = "";
    setActivePathD("");

    var gs = window.gameSocket;
    if (gs && gs.isInRoom() && gs.sendDrawingUndo) {
      gs.sendDrawingUndo();
    }
  }
}

// ── Receiver-side overlay for live remote strokes ────────────────────

function ensureRemotePathEl(strokeId, color, width) {
  var entry = remoteInProgress[strokeId];
  if (entry && entry.pathEl && entry.pathEl.isConnected) return entry;

  var svg = getSvg();
  if (!svg) return null;

  var p = document.createElementNS("http://www.w3.org/2000/svg", "path");
  p.setAttribute("d", "");
  p.setAttribute("stroke", color || "#000000");
  p.setAttribute("stroke-width", width || 2);
  p.setAttribute("fill", "none");
  p.setAttribute("stroke-linecap", "round");
  p.setAttribute("stroke-linejoin", "round");
  p.setAttribute("data-remote-in-progress", strokeId);

  // Insert before the drawer's active path if present, otherwise append.
  var activePath = getPathEl();
  if (activePath) {
    svg.insertBefore(p, activePath);
  } else {
    svg.appendChild(p);
  }

  entry = { pathEl: p, path: "", color: color || "#000000", width: width || 2 };
  remoteInProgress[strokeId] = entry;
  return entry;
}

export function applyRemoteChunk(strokeId, delta, color, width) {
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

// Removes a remote in-progress overlay by id. Called from a Hologram action
// alongside the state update that renders the canonical stroke, so the
// remove and add land in the same render cycle (no flicker).
export function removeRemoteOverlay(strokeId) {
  var entry = remoteInProgress[strokeId];
  if (!entry) return;
  if (entry.pathEl && entry.pathEl.parentNode) {
    entry.pathEl.parentNode.removeChild(entry.pathEl);
  }
  delete remoteInProgress[strokeId];
}

export function abandonRemoteStroke(strokeId) {
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
