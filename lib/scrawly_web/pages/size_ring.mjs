// The size ring: over a canvas, a ring that shows the exact footprint of the
// tool a stroke would start with (draw_tools.mjs: its size, at the canvas's
// current scale), solid for the brush and dashed for the eraser; a footprint
// under DOT_BELOW px is shown as the dot it paints. With Ctrl held a press
// would erase (gestureTool), so the ring is the eraser's until Ctrl is let
// go or the window loses focus (a Ctrl held while switching tabs never
// comes back up here). While a stroke is drawn the ring is that stroke's
// (the engine's gestureStyle): a right-button or Ctrl stroke stays the
// eraser's to its end, as the stroke does.
//
// It shows for a mouse or a pen over a canvas whose stroke engine is enabled
// (the drawer in :drawing, the home board once connected), also while a
// stroke is drawn, and hides for touch, when the pointer leaves the canvas
// and while the engine is off (viewers, the drawer between turns).
//
// Rendering: the ring is its own small svg (`.size-ring`) beside the canvas
// svg, in the canvas's frame, composited on a layer of its own (app.css:
// `will-change: transform`). Moving it is a transform the compositor
// applies: it never repaints the canvas, whose strokes share one raster
// layer (notes/files/drawing-benchmarks.md). Native pointer and key
// listeners only, no Hologram action or render: they only record the
// position and Ctrl, and the ring is written at most once per animation
// frame, only what changed.
//
// Scale: the svg's screen CTM, as the stroke engine maps pointers, so the
// ring is the stroke's real width wherever the canvas is shown (viewBox,
// letterboxing, zoom).
//
// Hologram 0.12 copies this module into every page bundle that can reach the
// importing page, so the rings (by canvas svg id) and the one set of window
// listeners live in window slots. The geometry is pure
// (test/js/size_ring.test.mjs).

import { MAIN_BUTTON, currentTool, gestureTool, onToolChange } from "./draw_tools.mjs";
import { strokeEngineFor } from "./stroke_engine.mjs";

const RINGS_SLOT = "__scrawlySizeRings";
const ROUTER_SLOT = "__scrawlySizeRingRouter";
// The ring's own state on its element: a re-rendered element starts afresh.
const DRAWN = "__sizeRing";

// The eraser's dashes, in px.
export const ERASER_DASH = "3 3";
// Below this diameter (px) a 1 px ring can't be as small as the footprint:
// the ring is the dot the stroke paints instead.
export const DOT_BELOW = 4;

// ── Geometry (no DOM) ────────────────────────────────────────────────

export function ringShownFor(pointerType) {
  return pointerType === "mouse" || pointerType === "pen";
}

// The ring for a stroke `size` canvas units wide, at `scale` px per unit.
// Two 1 px circles, centred in a `box` px square: a dark one whose outer edge
// is the stroke's edge (its diameter is the stroke's width), and a light one
// just inside it (null when there is no room), so the ring shows on white
// and on dark strokes alike. Under DOT_BELOW px it is one filled dot (`dot`)
// of the stroke's diameter.
export function ringGeometry(size, scale, eraser) {
  const diameter = Math.max(0, size * scale);
  const box = Math.ceil(diameter) + 2;
  const dot = diameter < DOT_BELOW;
  const inner = diameter / 2 - 1.5;
  return {
    diameter: diameter,
    box: box,
    center: box / 2,
    dot: dot,
    outer: dot ? diameter / 2 : diameter / 2 - 0.5,
    inner: !dot && inner >= 0.5 ? inner : null,
    dash: eraser && !dot ? ERASER_DASH : null,
  };
}

// What the ring shows, {size, eraser}: the stroke in progress (`drawing`,
// its engine's gestureStyle: {width, tool}) while there is one, else what a
// main-button press would draw now with `selected` and Ctrl as held.
export function ringLook(selected, drawing, pointerType, ctrl) {
  if (drawing && Number.isFinite(drawing.width)) {
    return { size: drawing.width, eraser: drawing.tool === "eraser" };
  }
  const t = gestureTool(selected, { pointerType: pointerType, button: MAIN_BUTTON, ctrlKey: ctrl === true });
  return { size: t.size, eraser: t.tool === "eraser" };
}

// Where the ring's box goes (its top-left corner, relative to `frame`, the
// element it is positioned in) for a pointer at clientX/clientY.
export function ringOffset(clientX, clientY, frame, box) {
  return { x: clientX - frame.left - box / 2, y: clientY - frame.top - box / 2 };
}

export function insideRect(x, y, r) {
  return x >= r.left && x <= r.right && y >= r.top && y <= r.bottom;
}

// ── Rings (window singletons) ────────────────────────────────────────

function rings() {
  if (!window[RINGS_SLOT]) window[RINGS_SLOT] = new Map();
  return window[RINGS_SLOT];
}

// {last, ctrl, frame}. last: the last pointer seen anywhere, {x, y, type,
// svgId} (svgId: the canvas svg it is over, or the one that captured it), or
// null once it left the page. ctrl: whether Ctrl is held, as the last
// pointer or key event said (false after the window lost focus).
function router() {
  return window[ROUTER_SLOT];
}

function schedule() {
  const r = router();
  if (r && !r.frame) r.frame = requestAnimationFrame(renderFrame);
}

function renderFrame() {
  const r = router();
  if (!r) return;
  r.frame = 0;
  rings().forEach((ring) => ring.update(r.last, r.ctrl));
}

function installRouter() {
  if (window[ROUTER_SLOT]) return;
  const r = { last: null, ctrl: false, frame: 0 };
  window[ROUTER_SLOT] = r;
  const overCanvas = () => !!(r.last && r.last.svgId);

  const track = function (e) {
    const t = e.target;
    const svg = t && typeof t.closest === "function" ? t.closest("svg[id]") : null;
    const was = overCanvas();
    r.last = { x: e.clientX, y: e.clientY, type: e.pointerType, svgId: svg ? svg.id : null };
    r.ctrl = e.ctrlKey === true;
    // Moves elsewhere on the page, before and after: nothing to draw.
    if (svg || was) schedule();
  };
  const left = function (e) {
    if (e.relatedTarget) return;
    r.last = null;
    schedule();
  };
  // A stroke ended: the ring is the selected tool's again.
  const released = function () {
    if (overCanvas()) schedule();
  };
  // Ctrl pressed or let go without a move (every key event says).
  const key = function (e) {
    if (typeof e.ctrlKey !== "boolean" || e.ctrlKey === r.ctrl) return;
    r.ctrl = e.ctrlKey;
    if (overCanvas()) schedule();
  };
  // The window's own blur (not capture: an element's blur doesn't bubble).
  const blurred = function (e) {
    if (e.target !== window || !r.ctrl) return;
    r.ctrl = false;
    schedule();
  };
  const opts = { capture: true, passive: true };
  window.addEventListener("pointermove", track, opts);
  window.addEventListener("pointerdown", track, opts);
  window.addEventListener("pointerout", left, opts);
  window.addEventListener("pointerup", released, opts);
  window.addEventListener("pointercancel", released, opts);
  window.addEventListener("keydown", key, opts);
  window.addEventListener("keyup", key, opts);
  window.addEventListener("blur", blurred, { passive: true });
  // The canvas moves or scales under a still pointer.
  window.addEventListener("scroll", schedule, opts);
  window.addEventListener("resize", schedule, { passive: true });
  onToolChange(schedule);
}

// Draws the ring of canvas `svgId` in the element `ringId` (DrawingCanvas,
// GameDemo). Registering again replaces the ring of that canvas.
export function ensureSizeRing(svgId, ringId) {
  installRouter();
  const existing = rings().get(svgId);
  if (existing && existing.ringId === ringId) return existing;
  const ring = { svgId: svgId, ringId: ringId, update: (p, ctrl) => update(svgId, ringId, p, ctrl) };
  rings().set(svgId, ring);
  schedule();
  return ring;
}

// After something the ring depends on changed without a pointer move (a
// canvas turned on or off).
export function refreshSizeRings() {
  schedule();
}

function update(svgId, ringId, p, ctrl) {
  const el = document.getElementById(ringId);
  if (!el) return;
  const svg = document.getElementById(svgId);
  const engine = strokeEngineFor(svgId);
  if (!p || p.svgId !== svgId || !ringShownFor(p.type) || !svg || !engine || !engine.isEnabled()) {
    hide(el, svg);
    return;
  }
  const ctm = typeof svg.getScreenCTM === "function" ? svg.getScreenCTM() : null;
  // The frame the ring is placed in; the canvas svg fills it.
  const frame = el.parentNode;
  const box = frame ? frame.getBoundingClientRect() : null;
  if (!ctm || !box || !insideRect(p.x, p.y, box)) {
    hide(el, svg);
    return;
  }
  const drawing = typeof engine.gestureStyle === "function" ? engine.gestureStyle() : null;
  const look = ringLook(currentTool(), drawing, p.type, ctrl);
  const g = ringGeometry(look.size, Math.hypot(ctm.a, ctm.b), look.eraser);
  draw(el, svg, g, ringOffset(p.x, p.y, box, g.box));
}

function state(el) {
  if (!el[DRAWN]) {
    el[DRAWN] = { shown: false, box: null, dot: false, outer: null, inner: null, dash: null, at: "" };
  }
  return el[DRAWN];
}

function hide(el, svg) {
  if (svg && svg.getAttribute("data-size-ring") !== null) svg.removeAttribute("data-size-ring");
  const s = state(el);
  if (!s.shown) return;
  s.shown = false;
  el.style.visibility = "hidden";
}

function draw(el, svg, g, at) {
  const s = state(el);
  // A new box moves the centre too.
  const boxChanged = s.box !== g.box;
  // Most frames only move the ring: the circles are looked up only for a
  // new size or tool.
  const reshape = boxChanged || s.dot !== g.dot || s.outer !== g.outer || s.inner !== g.inner || s.dash !== g.dash;
  const circles = reshape ? el.querySelectorAll("circle") : [];
  const outer = circles[0];
  const inner = circles[1];
  if (boxChanged) {
    // Inline, over the width app.css gives the svgs in the frame.
    el.style.width = g.box + "px";
    el.style.height = g.box + "px";
    s.box = g.box;
  }
  if (s.dot !== g.dot) {
    if (g.dot) el.setAttribute("data-dot", "");
    else el.removeAttribute("data-dot");
    s.dot = g.dot;
  }
  if (outer && (boxChanged || s.outer !== g.outer)) {
    setCircle(outer, g.center, g.outer);
    s.outer = g.outer;
  }
  if (inner && (boxChanged || s.inner !== g.inner)) {
    if (g.inner === null) inner.setAttribute("r", 0);
    else setCircle(inner, g.center, g.inner);
    s.inner = g.inner;
  }
  if (s.dash !== g.dash) {
    for (let i = 0; i < circles.length; i++) {
      if (g.dash) circles[i].setAttribute("stroke-dasharray", g.dash);
      else circles[i].removeAttribute("stroke-dasharray");
    }
    s.dash = g.dash;
  }
  const transform = "translate3d(" + at.x + "px, " + at.y + "px, 0)";
  if (s.at !== transform) {
    el.style.transform = transform;
    s.at = transform;
  }
  if (!s.shown) {
    s.shown = true;
    el.style.visibility = "visible";
    svg.setAttribute("data-size-ring", "");
  }
}

function setCircle(circle, center, r) {
  circle.setAttribute("cx", center);
  circle.setAttribute("cy", center);
  circle.setAttribute("r", r);
}
