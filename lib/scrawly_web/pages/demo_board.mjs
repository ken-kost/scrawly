// Bridge between the shared demo canvas SVG and the DemoBoard Phoenix channel.
// Keeps drawing smooth by mutating SVG paths directly — Hologram only ever sees
// the full strokes list on snapshot, never per-pixel state.

var socket = null;
var channel = null;
var strokes = [];        // completed strokes from the server [{path, color, width}]
var currentColor = "#000000";
var currentWidth = 2;
var currentEraser = false;
var activePath = "";

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
    renderStrokes();
  });
  channel.on("stroke", function(stroke) {
    strokes.push({ path: stroke.path, color: stroke.color, width: stroke.width });
    renderStrokes();
  });
  channel.on("cleared", function() {
    strokes = [];
    renderStrokes();
    setActivePathD("", currentColor, currentWidth);
    activePath = "";
  });
  channel.join().receive("error", function(resp) {
    console.error("Failed to join demo:board channel:", resp);
    channel = null;
  });
}

export function disconnectDemoBoard() {
  if (channel) { channel.leave(); channel = null; }
  if (socket) { socket.disconnect(); socket = null; }
  strokes = [];
}

export function startStroke(x, y) {
  var p = toViewBox(x, y);
  activePath = "M " + p[0] + " " + p[1];
  var c = currentEraser ? ERASER_COLOR : currentColor;
  var w = currentEraser ? ERASER_WIDTH : currentWidth;
  setActivePathD(activePath, c, w);
}

export function continueStroke(x, y) {
  if (!activePath) return;
  var p = toViewBox(x, y);
  activePath += " L " + p[0] + " " + p[1];
  var c = currentEraser ? ERASER_COLOR : currentColor;
  var w = currentEraser ? ERASER_WIDTH : currentWidth;
  setActivePathD(activePath, c, w);
}

export function endStroke() {
  if (!activePath) return;
  var c = currentEraser ? ERASER_COLOR : currentColor;
  var w = currentEraser ? ERASER_WIDTH : currentWidth;

  if (activePath.length > 5 && channel) {
    channel.push("draw", { path: activePath, color: c, width: w });
  }
  activePath = "";
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
