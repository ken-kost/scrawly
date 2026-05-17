// JS-managed SVG drawing — bypasses Hologram re-renders for smooth drawing.
// Supports color, width, stroke history, and undo.

var currentColor = "#000000";
var currentWidth = 2;
var strokeHistory = []; // completed strokes: [{path, color, width}, ...]
var currentStrokePath = ""; // path being drawn right now

function getPathEl() {
  return document.getElementById("drawing-path");
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

// Called on pointer_down — begin a new stroke
export function startStroke(x, y) {
  currentStrokePath = "M " + x + " " + y;
  setActivePathD(currentStrokePath);
}

// Called on pointer_move — extend the current stroke
export function continueStroke(x, y) {
  currentStrokePath += " L " + x + " " + y;
  setActivePathD(currentStrokePath);
}

// Called on pointer_up — complete the stroke, send to server, return path
export function endStroke() {
  if (currentStrokePath) {
    var stroke = { path: currentStrokePath, color: currentColor, width: currentWidth };
    strokeHistory.push(stroke);

    // Send completed stroke to server via channel
    var gs = window.gameSocket;
    if (gs && gs.isInRoom()) {
      if (gs.sendDrawingStroke) {
        gs.sendDrawingStroke(currentStrokePath, currentColor, currentWidth);
      } else {
        gs.sendDrawingSegment(currentStrokePath);
      }
    }

    // Render completed strokes and clear active path
    renderCompletedStrokes();
    currentStrokePath = "";
    setActivePathD("");
  }
  return currentStrokePath;
}

// Called on clear
export function clearDrawing() {
  strokeHistory = [];
  currentStrokePath = "";
  setActivePathD("");
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
  renderCompletedStrokes();
  setActivePathD("");
}

// Set the full path (legacy compat / non-drawer sync)
export function setDrawingPath(path) {
  if (!path || path === "") {
    strokeHistory = [];
    currentStrokePath = "";
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
