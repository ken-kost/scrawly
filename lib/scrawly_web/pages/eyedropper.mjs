// The colour picker tool (DrawingToolbar's "pick", key I), for both canvases
// (drawing_manager.mjs and demo_board.mjs install it with their stroke
// engine):
//
// * A press with the picker selected, or with Alt held and the brush
//   selected (a quick pick), picks the colour under the pointer instead of
//   drawing (draw_tools.mjs picksColor; Ctrl and the right button still
//   erase, whatever is selected). The stroke engine hands the press and its
//   viewBox point to the owner's takePress (pickPress here), which asks the
//   canvas's paint model (paint_model.mjs: the stroke list, never pixels)
//   and puts the colour into the tool at once: the brush in that colour
//   after the picker, or the tool used before it, the eraser coming back
//   as the brush (toolAfterPick); a quick pick keeps the brush. The page's
//   state (the chip, the swatches, the size dot) follows with one
//   `color_picked` action (color_picker.mjs reportColor). A pick on the
//   empty canvas, or on erased paint, is white: a colour like any other.
// * While a press would pick (the picker, or Alt with the brush), a small
//   swatch beside the pointer shows the colour under it (ensurePickSwatch:
//   `#game-canvas-pick` in DrawingCanvas, `#demo-board-pick` in GameDemo).
//   It follows size_ring.mjs's router (followPointer): native listeners,
//   written at most once per animation frame, only what changed, moved by a
//   transform on its own composited layer (app.css .pick-swatch). Like the
//   size ring it shows for a mouse or a pen over an enabled canvas only:
//   never for touch, viewers or a canvas that is off; and the ring hides
//   while it shows.
//
// Nothing here reaches the server, and nothing here runs while drawing: a
// pick is a press that starts no stroke, and the paint model makes its
// shapes on the first pick.
//
// Hologram 0.12 copies this module into every page bundle that can reach
// the importing page; its only state is per swatch element, and the router
// is size_ring.mjs's window singleton. The placement is pure
// (test/js/eyedropper.test.mjs).

import { CANVAS_COLOR } from "./paint_model.mjs";
import { MAIN_BUTTON, currentTool, picksColor, setDrawTool, toolAfterPick, toolBeforePicker } from "./draw_tools.mjs";
import { reportColor } from "./color_picker.mjs";
import { followPointer, insideRect, ringShownFor } from "./size_ring.mjs";
import { strokeEngineFor, toViewBox } from "./stroke_engine.mjs";

// app.css .pick-swatch: its size, and its gap to the pointer, in px.
export const SWATCH_SIZE = 22;
export const SWATCH_GAP = 12;

const HEX = /^#[0-9a-fA-F]{6}$/;
// The swatch's own state on its element: a re-rendered element starts afresh.
const DRAWN = "__pickSwatch";

// ── Pure parts ───────────────────────────────────────────────────────

// Where the swatch's top-left corner goes, in the frame's px, for a pointer
// at (x, y) in a `width` x `height` frame: above and to the right of the
// pointer, or on the other side of it where the frame's edge would cut it.
export function swatchOffset(x, y, width, height, size = SWATCH_SIZE, gap = SWATCH_GAP) {
  let left = x + gap;
  if (left + size > width) left = x - gap - size;
  let top = y - gap - size;
  if (top < 0) top = y + gap;
  return { x: left, y: top };
}

// The press a pointer would make now: the main button, the keys as held.
export function pressNow(pointerType, ctrl, alt) {
  return { pointerType: pointerType, button: MAIN_BUTTON, ctrlKey: ctrl === true, altKey: alt === true };
}

// ── The pick ─────────────────────────────────────────────────────────

// `color` (what the paint model says is under the pointer) into the tool,
// picked with the tool named `selected`; the page's state follows. Returns
// the colour as set (lowercase, as every native control sends it), or null
// for something that is no colour (nothing changes).
export function applyPick(color, selected) {
  if (typeof color !== "string" || !HEX.test(color)) return null;
  const hex = color.toLowerCase();
  setDrawTool({ tool: toolAfterPick(selected, toolBeforePicker()), color: hex });
  reportColor(hex);
  return hex;
}

// The stroke engine's takePress for a canvas whose colour at a point is
// `sample(ctx, x, y)` (ctx: the engine's canStart result): takes the press
// when it picks.
export function pickPress(sample) {
  return function (ctx, press, point) {
    const selected = currentTool();
    if (!picksColor(selected, press)) return false;
    applyPick(sample(ctx, point[0], point[1]), selected.tool);
    return true;
  };
}

// ── The swatch ───────────────────────────────────────────────────────

// Shows the colour under the pointer in the element `swatchId` (beside the
// canvas svg `svgId`, in its frame) while a press would pick; `sample(x,
// y)` is the colour at a viewBox point. Registering again replaces it.
export function ensurePickSwatch(svgId, swatchId, sample) {
  const el = document.getElementById(swatchId);
  // The element it shows on, if any: frames that don't pick and find it
  // hidden touch no DOM (every frame of a stroke).
  const swatch = { shownOn: el && el[DRAWN] && el[DRAWN].shown ? el : null };
  return followPointer(svgId + " pick", function (p, ctrl, alt) {
    update(swatch, svgId, swatchId, sample, p, ctrl, alt);
  });
}

function update(swatch, svgId, swatchId, sample, p, ctrl, alt) {
  const picking =
    !!p && p.svgId === svgId && ringShownFor(p.type) && picksColor(currentTool(), pressNow(p.type, ctrl, alt));
  if (!picking) {
    if (swatch.shownOn) hide(swatch, swatch.shownOn, document.getElementById(svgId));
    return;
  }
  const el = document.getElementById(swatchId);
  if (!el) return;
  const svg = document.getElementById(svgId);
  const engine = strokeEngineFor(svgId);
  const ctm = svg && typeof svg.getScreenCTM === "function" ? svg.getScreenCTM() : null;
  const frame = el.parentNode;
  const box = frame ? frame.getBoundingClientRect() : null;
  if (!engine || !engine.isEnabled() || engine.isDrawing() || !ctm || !box || !insideRect(p.x, p.y, box)) {
    hide(swatch, el, svg);
    return;
  }
  if (swatch.shownOn && swatch.shownOn !== el) hide(swatch, swatch.shownOn, null);
  const point = toViewBox(ctm.inverse(), p.x, p.y);
  const color = point ? sample(point[0], point[1]) : CANVAS_COLOR;
  show(swatch, el, svg, color, swatchOffset(p.x - box.left, p.y - box.top, box.width, box.height));
}

function state(el) {
  if (!el[DRAWN]) el[DRAWN] = { shown: false, color: null, at: "" };
  return el[DRAWN];
}

function hide(swatch, el, svg) {
  if (swatch.shownOn === el) swatch.shownOn = null;
  const s = state(el);
  if (!s.shown) return;
  s.shown = false;
  el.style.visibility = "hidden";
  if (svg) svg.removeAttribute("data-pick");
}

function show(swatch, el, svg, color, at) {
  swatch.shownOn = el;
  const s = state(el);
  if (s.color !== color) {
    el.style.background = color;
    s.color = color;
  }
  const transform = "translate3d(" + at.x + "px, " + at.y + "px, 0)";
  if (s.at !== transform) {
    el.style.transform = transform;
    s.at = transform;
  }
  if (!s.shown) {
    s.shown = true;
    el.style.visibility = "visible";
    svg.setAttribute("data-pick", "");
  }
}
