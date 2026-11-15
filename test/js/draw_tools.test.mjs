// The drawing tool model (lib/scrawly_web/pages/draw_tools.mjs), shared by
// the in-game canvas and the home page's board: validation, the stroke a
// tool draws, and one model for every bundle's copy of the module.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

globalThis.window = globalThis;

const MODULE = "../../lib/scrawly_web/pages/draw_tools.mjs";
const tools = await import(MODULE);
// Hologram 0.12 puts a copy of the module in every page bundle that can
// reach the importing page: a second URL gives node a second instance.
const copy = await import(MODULE + "?bundle=game");

const { DEFAULT_TOOL, ERASER, MIN_SIZE, MAX_SIZE, TOOLS } = tools;

// Scrawly.Games.StrokeRules.valid_color?/1 and valid_width?/1.
const VALID_COLOR = /^#[0-9a-fA-F]{6}$/;
const validWidth = (w) => Number.isInteger(w) && w >= 1 && w <= 40;

beforeEach(() => {
  tools.resetDrawTool();
});

test("normalizeTool keeps valid fields and takes the others from the base", () => {
  assert.deepEqual(tools.normalizeTool({ tool: "eraser", color: "#d63838", size: 10 }), {
    tool: "eraser",
    color: "#d63838",
    size: 10,
  });

  for (const bad of [null, undefined, "brush", 3, []]) {
    assert.deepEqual(tools.normalizeTool(bad), { ...DEFAULT_TOOL });
  }

  const base = { tool: "eraser", color: "#2a6df4", size: 5 };
  const invalid = [
    { tool: "pen" },
    { tool: ":brush" },
    { color: "red" },
    { color: "#fff" },
    { color: "#0000000" },
    { size: 0 },
    { size: 41 },
    { size: 2.5 },
    { size: "2" },
  ];
  for (const value of invalid) {
    assert.deepEqual(tools.normalizeTool(value, base), base, JSON.stringify(value));
  }

  assert.equal(tools.normalizeTool({ size: MIN_SIZE }).size, MIN_SIZE);
  assert.equal(tools.normalizeTool({ size: MAX_SIZE }).size, MAX_SIZE);
});

test("the brush draws in its colour and size; the eraser white at its own size", () => {
  assert.deepEqual(tools.strokeStyle({ tool: "brush", color: "#d63838", size: 10 }), {
    color: "#d63838",
    width: 10,
  });

  for (const size of [2, 5, 10, 20]) {
    assert.deepEqual(tools.strokeStyle({ tool: "eraser", color: "#d63838", size }), {
      color: "#ffffff",
      width: ERASER.size,
    });
  }

  assert.deepEqual(tools.strokeStyle(undefined), {
    color: DEFAULT_TOOL.color,
    width: DEFAULT_TOOL.size,
  });
});

test("every tool draws a stroke the server accepts", () => {
  for (const tool of TOOLS) {
    for (const size of [MIN_SIZE, 2, 20, MAX_SIZE]) {
      const style = tools.strokeStyle({ tool, color: "#a855f7", size });
      assert.match(style.color, VALID_COLOR);
      assert.ok(validWidth(style.width), `${tool} at ${size}: width ${style.width}`);
    }
  }
});

test("setDrawTool merges a partial change and ignores invalid fields", () => {
  assert.deepEqual(tools.currentTool(), { ...DEFAULT_TOOL });

  tools.setDrawTool({ tool: "brush", color: "#d63838", size: 10 });
  assert.deepEqual(tools.setDrawTool({ size: 5 }), { tool: "brush", color: "#d63838", size: 5 });
  assert.deepEqual(tools.setDrawTool({ tool: "eraser" }), {
    tool: "eraser",
    color: "#d63838",
    size: 5,
  });
  assert.deepEqual(tools.setDrawTool({ tool: "fill", color: "nope", size: 99 }), {
    tool: "eraser",
    color: "#d63838",
    size: 5,
  });
  assert.deepEqual(tools.setDrawTool(null), tools.currentTool());

  // A copy, not the model itself.
  tools.currentTool().size = 40;
  assert.equal(tools.currentTool().size, 5);

  assert.deepEqual(tools.resetDrawTool(), { ...DEFAULT_TOOL });
});

test("every bundle's copy of the module shares one model", () => {
  tools.setDrawTool({ tool: "eraser", color: "#1f9a4a", size: 20 });
  assert.deepEqual(copy.currentTool(), tools.currentTool());

  copy.resetDrawTool();
  assert.deepEqual(tools.currentTool(), { ...DEFAULT_TOOL });
});
