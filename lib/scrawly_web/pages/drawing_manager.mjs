
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

var remoteInProgress = {};

var completedStrokeIds = {};

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
  var svg = getPathEl() ? getPathEl().closest("svg") : null;
  if (!svg) return;

  var old = svg.querySelectorAll("[data-completed]");
  for (var i = 0; i < old.length; i++) {
    old[i].remove();
  }

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

export function startStroke(x, y) {
  currentStrokePath = "M " + x + " " + y;
  currentStrokeId = makeStrokeId();
  currentSeq = 0;
  pendingDelta = currentStrokePath;
  setActivePathD(currentStrokePath);
  flushPending();
}

export function continueStroke(x, y) {
  var delta = " L " + x + " " + y;
  currentStrokePath += delta;
  pendingDelta += delta;
  setActivePathD(currentStrokePath);
  scheduleFlush();
}

export function endStroke() {
  if (flushTimer) {
    clearTimeout(flushTimer);
    flushTimer = null;
  }
  flushPending();

  if (currentStrokePath) {
    var stroke = { path: currentStrokePath, color: currentColor, width: currentWidth };
    strokeHistory.push(stroke);

    if (globalThis.Hologram && currentStrokeId) {
      globalThis.Hologram.dispatchAction("commit_stroke", "page", {
        stroke_id: currentStrokeId,
        path: currentStrokePath,
        color: currentColor,
        width: currentWidth
      });
    }

    renderCompletedStrokes();
    currentStrokePath = "";
    currentStrokeId = null;
    setActivePathD("");
  }
  return currentStrokePath;
}

export function clearDrawing() {
  strokeHistory = [];
  currentStrokePath = "";
  setActivePathD("");
  clearRemoteOverlay();
  renderCompletedStrokes();
}

export function setStrokes(strokes) {
  strokeHistory = (strokes || []).map(function(s) {
    return { path: s.path || "", color: s.color || "#000000", width: s.width || 2 };
  });
  currentStrokePath = "";
  clearRemoteOverlay();
  renderCompletedStrokes();
  setActivePathD("");
}

export function setDrawingPath(path) {
  if (!path || path === "") {
    strokeHistory = [];
    currentStrokePath = "";
    clearRemoteOverlay();
    renderCompletedStrokes();
    setActivePathD("");
  }
}

export function getDrawingPath() {
  var parts = strokeHistory.map(function(s) { return s.path; });
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

export function undoStroke() {
  if (currentStrokeId) return;
  if (strokeHistory.length > 0) {
    strokeHistory.pop();
    renderCompletedStrokes();
    currentStrokePath = "";
    setActivePathD("");

    if (globalThis.Hologram) {
      globalThis.Hologram.dispatchAction("commit_undo", "page", {});
    }
  }
}


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
  if (completedStrokeIds[strokeId]) return;
  var entry = ensureRemotePathEl(strokeId, color, width);
  if (!entry) return;
  entry.path += delta;
  entry.color = color || entry.color;
  entry.width = width || entry.width;
  entry.pathEl.setAttribute("d", entry.path);
  entry.pathEl.setAttribute("stroke", entry.color);
  entry.pathEl.setAttribute("stroke-width", entry.width);
}

export function removeRemoteOverlay(strokeId) {
  completedStrokeIds[strokeId] = true;
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
  completedStrokeIds = {};
}
