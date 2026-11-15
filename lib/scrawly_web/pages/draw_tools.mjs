// The drawing tool: one model for both canvases, the in-game canvas
// (drawing_manager.mjs) and the home page's shared board (demo_board.mjs).
//
//   {tool: "brush" | "eraser", color: "#rrggbb", size: 1..40}
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
// The eraser is a white stroke (the canvas is white in both themes,
// `--canvas` in app.css), ERASER.size wide.
//
// A new tool joins TOOLS (and strokeStyle, if it draws differently); a
// control that changes the tool natively (no Hologram action) calls
// setDrawTool itself, with only the fields it changes.
//
// Hologram 0.12 copies this module into every page bundle that can reach the
// importing page, so the model lives in one window slot that every copy
// shares. Everything else here is pure (test/js/draw_tools.test.mjs).

export const TOOLS = Object.freeze(["brush", "eraser"]);
// Scrawly.Games.StrokeRules.valid_width?/1.
export const MIN_SIZE = 1;
export const MAX_SIZE = 40;
export const ERASER = Object.freeze({ color: "#ffffff", size: 20 });
// The same as DrawingToolbar.default_tool/0 (a test keeps them equal): what
// a canvas draws with until its page pushes a tool, and after resetDrawTool.
export const DEFAULT_TOOL = Object.freeze({ tool: "brush", color: "#0a0a0a", size: 2 });

const SLOT = "__scrawlyDrawTool";
const HEX_COLOR = /^#[0-9a-fA-F]{6}$/;

// A valid tool from `value`; each missing or invalid field comes from `base`.
export function normalizeTool(value, base = DEFAULT_TOOL) {
  const v = value && typeof value === "object" ? value : {};
  return {
    tool: TOOLS.includes(v.tool) ? v.tool : base.tool,
    color: typeof v.color === "string" && HEX_COLOR.test(v.color) ? v.color : base.color,
    size: Number.isInteger(v.size) && v.size >= MIN_SIZE && v.size <= MAX_SIZE ? v.size : base.size,
  };
}

// What a stroke drawn with `tool` looks like (the engine's getTool result).
export function strokeStyle(tool) {
  const t = normalizeTool(tool);
  if (t.tool === "eraser") return { color: ERASER.color, width: ERASER.size };
  return { color: t.color, width: t.size };
}

function model() {
  if (!window[SLOT]) window[SLOT] = { ...DEFAULT_TOOL };
  return window[SLOT];
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
  window[SLOT] = normalizeTool({ ...current, ...changes }, current);
  return currentTool();
}

// Back to DEFAULT_TOOL (a new game page, drawing_manager.mjs mountCanvas).
export function resetDrawTool() {
  window[SLOT] = { ...DEFAULT_TOOL };
  return currentTool();
}
