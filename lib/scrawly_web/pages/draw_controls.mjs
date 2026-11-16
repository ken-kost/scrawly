// The drawing toolbar's native input, for both canvases (drawing_manager.mjs
// and demo_board.mjs install it with their stroke engine):
//
// * The size slider (DrawingToolbar's `input[data-draw-size]`) writes the
//   tool model (draw_tools.mjs) on every `input`, so a stroke started right
//   after dragging uses the new size. Its own Hologram binding
//   (`$change.throttle`) brings the page's state, and with it the readout,
//   along behind; dragging runs no action per value.
//
// * The keyboard shortcuts. Every drawing shortcut goes through this one
//   keydown listener, and through its typing guard: nothing happens while
//   focus is in a field you type in (isTypingTarget: text inputs, textarea,
//   select, contenteditable), wherever it is (the chat, the layout's login
//   and register forms, Home's code field and lobby chat, a page's own
//   modals), and the key keeps its native meaning there (Ctrl+Z undoes the
//   typing). A shortcut is live only while a toolbar names it in its
//   `data-draw-shortcuts` (DrawingToolbar with `shortcuts`; the names are
//   its controls). Then it either dispatches the page's own toolbar action
//   (the toolbar is stateless, its events go to the page) or, for the size
//   keys, steps the slider exactly as a drag would (its value, then an
//   `input` event), so a key and a drag take one path to the model and the
//   state.
//
// A new shortcut is one entry in SHORTCUTS (and the control's name in
// DrawingToolbar's shortcut list); it gets the guard for free.
//
// Ctrl/Cmd+Z is the one shortcut that skips the page: it calls the undo of
// the canvas in the document directly (registerCanvasUndo: the game
// canvas's and the board's own), so the stroke leaves the canvas in the key's
// own task, with no Hologram action or page render first (the page action,
// which the toolbar's undo button keeps, did just that, a timer hop later).
// Without a registered canvas it dispatches the page's action as before.
//
// * The colour panel's own input (wheel, brightness, hex field, swatch
//   arrows) is color_picker.mjs, installed with these. Escape is no
//   drawing shortcut: it closes the colour panel (DrawingToolbar's
//   `<window $key_down.escape>`, whose listener is attached when the panel
//   opens, so after this one: this listener sees Escape first and must keep
//   ignoring it). color_picker.mjs's own keys run in the capture phase and
//   prevent the default of what they handle, which this listener skips.
//
// Hologram 0.12 copies this module into every page bundle that can reach the
// importing page, so the listeners are installed once per tab (window slot).
// Everything but installDrawControls is pure (test/js/draw_controls.test.mjs).

import { installColorPicker } from "./color_picker.mjs";
import { clampSize, currentTool, setDrawTool, stepSize } from "./draw_tools.mjs";

const SLOT = "__scrawlyDrawControls";
const UNDO_SLOT = "__scrawlyCanvasUndo";
const TOOLBAR_SELECTOR = "[data-draw-shortcuts]";
const SIZE_ATTR = "data-draw-size";
const SIZE_SELECTOR = "input[" + SIZE_ATTR + "]";

// The size keys' steps: 1, or 5 with Shift.
export const SIZE_STEP = 1;
export const SIZE_STEP_SHIFT = 5;

// Input types that take no typing: a shortcut works with one of these
// focused (e.g. the size slider itself, after a drag).
const NON_TEXT_INPUTS = new Set([
  "button",
  "checkbox",
  "color",
  "file",
  "hidden",
  "image",
  "radio",
  "range",
  "reset",
  "submit",
]);

// Whether `el` (a keydown's target) is a field the user types in.
export function isTypingTarget(el) {
  if (!el || typeof el !== "object") return false;
  if (el.isContentEditable === true) return true;
  const tag = typeof el.tagName === "string" ? el.tagName.toLowerCase() : "";
  if (tag === "textarea" || tag === "select") return true;
  if (tag !== "input") return false;
  const type = typeof el.type === "string" && el.type !== "" ? el.type.toLowerCase() : "text";
  return !NON_TEXT_INPUTS.has(type);
}

function key(e) {
  return typeof e.key === "string" ? e.key.toLowerCase() : "";
}

// No Ctrl, Cmd or Alt (Shift is fine: Shift+E is still E).
function plain(e) {
  return !e.ctrlKey && !e.metaKey && !e.altKey;
}

// "[" / "]" (or "{" / "}", the same keys with Shift). Cmd and Ctrl are the
// browser's (Cmd+[ is Back), except Ctrl+Alt, which is AltGr: where "[" is
// typed with AltGr (or Alt on a Mac), it still counts.
function sizeKey(e, chars) {
  if (e.metaKey || (e.ctrlKey && !e.altKey)) return false;
  return chars.includes(e.key);
}

// Each shortcut: the toolbar control it belongs to (DrawingToolbar's
// shortcut names), the keys (`match`), and what it does: `action`, the
// page's toolbar action, or `step`, a step of the size slider (times
// SIZE_STEP_SHIFT with Shift). Held keys auto-repeat only where that makes
// sense (the size keys).
export const SHORTCUTS = Object.freeze([
  {
    control: "brush",
    action: "select_brush",
    match: (e) => plain(e) && !e.repeat && key(e) === "b",
  },
  {
    // A toggle (back to the brush the second time), as the button is.
    control: "eraser",
    action: "toggle_eraser",
    match: (e) => plain(e) && !e.repeat && key(e) === "e",
  },
  {
    // The colour picker, a toggle like E (eyedropper.mjs picks).
    control: "picker",
    action: "toggle_picker",
    match: (e) => plain(e) && !e.repeat && key(e) === "i",
  },
  {
    // The fill, a toggle like E (fill_tool.mjs fills).
    control: "fill",
    action: "toggle_fill",
    match: (e) => plain(e) && !e.repeat && key(e) === "f",
  },
  {
    // Ctrl+Z or Cmd+Z (both at once undo once: one event). With Shift it is
    // redo elsewhere, so it does nothing here.
    control: "undo",
    action: "undo_drawing",
    match: (e) => (e.ctrlKey || e.metaKey) && !e.shiftKey && !e.repeat && key(e) === "z",
  },
  { control: "size", step: -1, match: (e) => sizeKey(e, ["[", "{"]) },
  { control: "size", step: 1, match: (e) => sizeKey(e, ["]", "}"]) },
]);

// The shortcut `e` triggers among the `controls` a toolbar names, as
// {control, action} or {control, step} (the step already times Shift's), or
// null.
export function matchShortcut(e, controls) {
  if (!e || typeof e.key !== "string" || e.isComposing) return null;
  const live = Array.isArray(controls) ? controls : [];
  for (const s of SHORTCUTS) {
    if (!live.includes(s.control) || !s.match(e)) continue;
    if (s.step) return { control: s.control, step: s.step * (e.shiftKey ? SIZE_STEP_SHIFT : SIZE_STEP) };
    return { control: s.control, action: s.action };
  }
  return null;
}

// The names in a toolbar's data-draw-shortcuts.
export function toolbarShortcuts(toolbar) {
  const names = toolbar && toolbar.getAttribute ? toolbar.getAttribute("data-draw-shortcuts") : null;
  return typeof names === "string" ? names.split(/\s+/).filter(Boolean) : [];
}

// Moves the size slider `input` from `size` by `delta` the way a drag does:
// its value, then an `input` event (the native listener below writes the
// model, the slider's Hologram binding the state). False at an end already.
//
// `size` is the model's, not the slider's value: the slider is a Hologram
// controlled input, and any render while its throttled state lags behind
// (e.g. GamePage's countdown tick, every second) puts the lagging value back
// into it until the throttle's trailing dispatch, which carries the latest
// value, catches the state up.
export function stepSizeInput(input, size, delta) {
  const next = stepSize(size, delta);
  if (next === size) return false;
  input.value = String(next);
  input.dispatchEvent(new Event("input", { bubbles: true }));
  return true;
}

// A canvas's own undo, by the id of its svg (drawing_manager.mjs undoStroke,
// demo_board.mjs undoBoard): what Ctrl/Cmd+Z calls while that svg is in the
// document. Registering the same id again replaces it.
export function registerCanvasUndo(svgId, undo) {
  if (!window[UNDO_SLOT]) window[UNDO_SLOT] = new Map();
  window[UNDO_SLOT].set(svgId, undo);
}

function canvasUndo() {
  const undos = window[UNDO_SLOT];
  if (!undos) return null;
  for (const [svgId, undo] of undos) {
    if (document.getElementById(svgId)) return undo;
  }
  return null;
}

// The slider's value into the tool model, before any binding of the slider
// sees the event (window, capture phase).
function onInput(e) {
  const el = e.target;
  if (!el || typeof el.hasAttribute !== "function" || !el.hasAttribute(SIZE_ATTR)) return;
  const size = clampSize(Number(el.value));
  if (size !== null) setDrawTool({ size: size });
}

// Bubble phase: an element that handles the key itself (and stops it or
// prevents its default) keeps it.
function onKeyDown(e) {
  if (e.defaultPrevented) return;
  const toolbar = document.querySelector(TOOLBAR_SELECTOR);
  if (!toolbar || isTypingTarget(e.target)) return;
  const hit = matchShortcut(e, toolbarShortcuts(toolbar));
  if (!hit) return;

  if (hit.step) {
    const input = toolbar.querySelector(SIZE_SELECTOR);
    if (!input) return;
    e.preventDefault();
    stepSizeInput(input, currentTool().size, hit.step);
    return;
  }

  if (hit.control === "undo") {
    const undo = canvasUndo();
    if (undo) {
      e.preventDefault();
      undo();
      return;
    }
  }

  if (!globalThis.Hologram) return;
  e.preventDefault();
  globalThis.Hologram.dispatchAction(hit.action, "page", {});
}

// Once per tab, with the colour panel's input.
export function installDrawControls() {
  installColorPicker();
  if (window[SLOT]) return;
  window.addEventListener("input", onInput, true);
  window.addEventListener("keydown", onKeyDown, false);
  window[SLOT] = { onInput: onInput, onKeyDown: onKeyDown };
}
