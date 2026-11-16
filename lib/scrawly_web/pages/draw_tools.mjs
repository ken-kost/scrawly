// The drawing tool: one model for both canvases, the in-game canvas
// (drawing_manager.mjs) and the home page's shared board (demo_board.mjs).
//
//   {tool: "brush" | "eraser" | "picker", color: "#rrggbb", size: 1..40}
//
// The page showing a canvas owns the tool in its state (`draw_tool`, shown
// by ScrawlyWeb.Components.DrawingToolbar, changed by its actions) and
// pushes it here with setDrawTool: on every change, when the canvas mounts
// and after a Back/Forward restore. A canvas reads it once per stroke, when
// the stroke starts (its stroke engine's getTool):
//
//   strokeStyle(currentTool())  -> {color, width}
//
// so choosing a tool costs one Hologram action, and drawing none.
//
// The size is one for the brush and the eraser. The toolbar's slider writes
// it here natively, on every `input` (draw_controls.mjs), so a stroke started
// right after dragging uses it; the page's state follows, throttled.
//
// The eraser is a white stroke (the canvas is white in both themes,
// `--canvas` in app.css) at the tool's size.
//
// A gesture can also erase without selecting the eraser: with the right
// mouse button (a pen's barrel button), or Ctrl held at the press
// (gestureTool). The engine asks at the press, with the press event:
//
//   gestureStroke(currentTool(), pointerdownEvent)  -> {color, width, tool}
//
// and the gesture keeps that tool until it ends. The selected tool, and the
// toolbar showing it, never change for it.
//
// The picker draws nothing: a press with it picks the colour under the
// pointer (eyedropper.mjs), and so does an Alt+press with the brush
// (picksColor). After a pick the tool is toolAfterPick's: the one used
// before the picker, the eraser coming back as the brush (the picked colour
// is to paint with). The tool before the picker is noted here, whenever the
// picker is selected (toolBeforePicker).
//
// A new tool joins TOOLS (and strokeStyle, if it draws differently); a
// control that changes the tool natively (no Hologram action) calls
// setDrawTool itself, with only the fields it changes. Whatever shows the
// tool natively (the size ring, size_ring.mjs) follows it with onToolChange.
//
// Hologram 0.12 copies this module into every page bundle that can reach the
// importing page, so the model and its listeners live in window slots that
// every copy shares. Everything else here is pure
// (test/js/draw_tools.test.mjs).

export const TOOLS = Object.freeze(["brush", "eraser", "picker"]);
// Scrawly.Games.StrokeRules.valid_width?/1.
export const MIN_SIZE = 1;
export const MAX_SIZE = 40;
export const ERASER = Object.freeze({ color: "#ffffff" });
// The same as DrawingToolbar.default_tool/0 (a test keeps them equal): what
// a canvas draws with until its page pushes a tool, and after resetDrawTool.
export const DEFAULT_TOOL = Object.freeze({ tool: "brush", color: "#0a0a0a", size: 4 });

const SLOT = "__scrawlyDrawTool";
const LISTENERS_SLOT = "__scrawlyDrawToolListeners";
const BEFORE_PICKER_SLOT = "__scrawlyDrawToolBeforePicker";
const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

// A whole size clamped to MIN_SIZE..MAX_SIZE; null for anything else.
export function clampSize(value) {
  if (!Number.isInteger(value)) return null;
  return Math.min(MAX_SIZE, Math.max(MIN_SIZE, value));
}

// `size` moved by `delta`, clamped (the bracket keys).
export function stepSize(size, delta) {
  return clampSize((clampSize(size) || DEFAULT_TOOL.size) + delta);
}

// A valid tool from `value`; each missing or invalid field comes from `base`.
// A whole size out of range is clamped.
export function normalizeTool(value, base = DEFAULT_TOOL) {
  const v = value && typeof value === "object" ? value : {};
  const size = clampSize(v.size);
  return {
    tool: TOOLS.includes(v.tool) ? v.tool : base.tool,
    color: typeof v.color === "string" && HEX_COLOR.test(v.color) ? v.color : base.color,
    size: size === null ? base.size : size,
  };
}

// What a stroke drawn with `tool` looks like (the picker draws none: the
// brush's, should anything ask).
export function strokeStyle(tool) {
  const t = normalizeTool(tool);
  if (t.tool === "eraser") return { color: ERASER.color, width: t.size };
  return { color: t.color, width: t.size };
}

// PointerEvent.button at a press: the main button (a mouse's left, a pen's
// tip, a touch) and the secondary one (a mouse's right, a pen's barrel).
export const MAIN_BUTTON = 0;
export const SECONDARY_BUTTON = 2;

// The tool a gesture draws with: the eraser, at the selected size, when the
// press (a pointerdown: {pointerType, button, ctrlKey, altKey}) is the
// secondary button, or the main button with Ctrl held, whatever tool is
// selected; the picker for the main button with Alt held and the brush
// selected (a quick pick); otherwise the selected tool.
//
// * macOS turns Ctrl+click into a secondary click: some browsers report it
//   as button 2, others as button 0 with ctrlKey. Either erases.
// * Cmd (metaKey) is not Ctrl: Cmd+click draws with the selected tool.
// * Ctrl wins over Alt (Ctrl+Alt is AltGr on some keyboards): it erases.
// * Touch has no modifiers here: a touch always draws with the selected
//   tool (touch users have the eraser and pick buttons).
export function gestureTool(selected, press) {
  const t = normalizeTool(selected);
  const p = press && typeof press === "object" ? press : {};
  if (p.pointerType === "touch") return t;
  const erase = p.button === SECONDARY_BUTTON || (p.button === MAIN_BUTTON && p.ctrlKey === true);
  if (erase) return { ...t, tool: "eraser" };
  if (p.button === MAIN_BUTTON && p.altKey === true && t.tool === "brush") return { ...t, tool: "picker" };
  return t;
}

// Whether `press` picks a colour (the picker, or Alt with the brush)
// instead of starting a stroke.
export function picksColor(selected, press) {
  return gestureTool(selected, press).tool === "picker";
}

// The tools a pick comes back to as they were; any other (the eraser, the
// picker itself, nothing noted) comes back as the brush.
const BACK_AFTER_PICK = Object.freeze(["brush"]);

// The tool after a pick made with `selected` (its name): a quick pick keeps
// the brush; the picker gives way to `before`, the tool used before it
// (toolBeforePicker), the eraser turning into the brush.
export function toolAfterPick(selected, before) {
  const back = selected === "picker" ? before : selected;
  return BACK_AFTER_PICK.includes(back) ? back : "brush";
}

// What a gesture started by `press` draws (the stroke engine's getTool):
// its gestureTool's strokeStyle, and that tool's name.
export function gestureStroke(selected, press) {
  const t = gestureTool(selected, press);
  return { ...strokeStyle(t), tool: t.tool };
}

function model() {
  if (!window[SLOT]) window[SLOT] = { ...DEFAULT_TOOL };
  return window[SLOT];
}

function listeners() {
  if (!window[LISTENERS_SLOT]) window[LISTENERS_SLOT] = new Set();
  return window[LISTENERS_SLOT];
}

function put(tool) {
  const before = window[SLOT];
  window[SLOT] = tool;
  if (tool.tool === "picker" && before && before.tool !== "picker") window[BEFORE_PICKER_SLOT] = before.tool;
  const changed =
    !before || before.tool !== tool.tool || before.color !== tool.color || before.size !== tool.size;
  if (changed) listeners().forEach((fn) => fn({ ...tool }));
  return { ...tool };
}

// A copy of the current tool.
export function currentTool() {
  return { ...model() };
}

// Merges `partial` into the current tool (invalid fields are ignored) and
// returns the result.
export function setDrawTool(partial) {
  const current = model();
  const changes = partial && typeof partial === "object" ? partial : {};
  return put(normalizeTool({ ...current, ...changes }, current));
}

// The tool selected before the picker, last time it was selected (null if
// it never was in this tab).
export function toolBeforePicker() {
  return window[BEFORE_PICKER_SLOT] || null;
}

// Back to DEFAULT_TOOL (a new game page, drawing_manager.mjs mountCanvas).
export function resetDrawTool() {
  return put({ ...DEFAULT_TOOL });
}

// Calls `fn(tool)` after every change of the tool, until the returned
// function is called.
export function onToolChange(fn) {
  listeners().add(fn);
  return () => listeners().delete(fn);
}
