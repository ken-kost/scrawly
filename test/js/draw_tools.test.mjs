// The drawing tool model (lib/scrawly_web/pages/draw_tools.mjs), shared by
// the in-game canvas and the home page's board: validation, the size model
// (clamped to 1..40, one size for the brush and the eraser), the stroke a
// tool draws, the tool for one gesture (the right button or Ctrl erases,
// Alt with the brush picks a colour), the tool after a pick, change
// listeners, and one model for every bundle's copy of the module.
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
    { size: 2.5 },
    { size: "2" },
    { size: NaN },
    { size: null },
  ];
  for (const value of invalid) {
    assert.deepEqual(tools.normalizeTool(value, base), base, JSON.stringify(value));
  }

  assert.equal(tools.normalizeTool({ size: MIN_SIZE }).size, MIN_SIZE);
  assert.equal(tools.normalizeTool({ size: MAX_SIZE }).size, MAX_SIZE);
});

test("the size model clamps a whole size to 1..40", () => {
  assert.deepEqual([MIN_SIZE, MAX_SIZE], [1, 40]);
  assert.deepEqual(
    [-5, 0, 1, 4, 40, 41, 1000].map(tools.clampSize),
    [1, 1, 1, 4, 40, 40, 40]
  );
  for (const bad of [2.5, "4", NaN, Infinity, null, undefined]) {
    assert.equal(tools.clampSize(bad), null, String(bad));
  }

  assert.equal(tools.normalizeTool({ size: 0 }).size, MIN_SIZE);
  assert.equal(tools.normalizeTool({ size: 41 }).size, MAX_SIZE);

  // The bracket keys' steps.
  assert.equal(tools.stepSize(4, 1), 5);
  assert.equal(tools.stepSize(4, -5), 1);
  assert.equal(tools.stepSize(38, 5), 40);
  assert.equal(tools.stepSize(1, -1), 1);
  assert.equal(tools.stepSize(NaN, 1), DEFAULT_TOOL.size + 1);

  tools.setDrawTool({ size: 99 });
  assert.equal(tools.currentTool().size, MAX_SIZE);
});

test("the brush draws in its colour and size; the eraser white at the same size", () => {
  assert.deepEqual(tools.strokeStyle({ tool: "brush", color: "#d63838", size: 10 }), {
    color: "#d63838",
    width: 10,
  });

  for (const size of [MIN_SIZE, 4, 10, MAX_SIZE]) {
    assert.deepEqual(tools.strokeStyle({ tool: "eraser", color: "#d63838", size }), {
      color: ERASER.color,
      width: size,
    });
  }
  assert.equal(ERASER.color, "#ffffff");

  assert.deepEqual(tools.strokeStyle(undefined), {
    color: DEFAULT_TOOL.color,
    width: DEFAULT_TOOL.size,
  });
});

test("every tool draws a stroke the server accepts", () => {
  for (const tool of TOOLS) {
    for (const size of [MIN_SIZE, 4, 20, MAX_SIZE]) {
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
  assert.deepEqual(tools.setDrawTool({ tool: "fill", color: "nope", size: 2.5 }), {
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

test("listeners hear every change, from any copy, and nothing else", () => {
  const heard = [];
  const stop = tools.onToolChange((tool) => heard.push(tool));

  tools.setDrawTool({ size: 12 });
  tools.setDrawTool({ size: 12 });
  copy.setDrawTool({ tool: "eraser" });
  tools.setDrawTool({ size: "nope" });
  copy.resetDrawTool();
  assert.deepEqual(heard, [
    { ...DEFAULT_TOOL, size: 12 },
    { ...DEFAULT_TOOL, tool: "eraser", size: 12 },
    { ...DEFAULT_TOOL },
  ]);

  // A copy, not the model.
  heard[0].size = 30;
  assert.equal(tools.currentTool().size, DEFAULT_TOOL.size);

  stop();
  tools.setDrawTool({ size: 30 });
  assert.equal(heard.length, 3);
});

// ── The tool for one gesture (quick-erase) ──────────────────────────

// The decision, spelled out: the selected tool, except that a mouse's or a
// pen's secondary button (right, barrel), or its main button with Ctrl,
// erases, whatever is selected; its main button with Alt (and no Ctrl)
// picks a colour when the brush is selected; touch always gets the
// selected tool; Cmd is nothing.
function expectedTool(selected, { pointerType, button, ctrlKey, altKey }) {
  if (pointerType === "touch") return selected.tool;
  if (button === 2) return "eraser";
  if (button === 0 && ctrlKey) return "eraser";
  if (button === 0 && altKey && selected.tool === "brush") return "picker";
  return selected.tool;
}

test("gestureTool, for every selected tool, pointer, button, Ctrl, Alt and Cmd", () => {
  const selections = [
    { tool: "brush", color: "#d63838", size: 7 },
    { tool: "eraser", color: "#2a6df4", size: 33 },
    { tool: "picker", color: "#1f9a4a", size: 12 },
  ];
  assert.deepEqual(selections.map((s) => s.tool), [...TOOLS]);
  // -1: no button changed (what a move reports); 1 middle, 3 back, 4
  // forward, 5 a pen's eraser button.
  const buttons = [0, 1, 2, 3, 4, 5, -1, undefined];
  let cases = 0;

  for (const selected of selections) {
    for (const pointerType of ["mouse", "pen", "touch"]) {
      for (const button of buttons) {
        for (const ctrlKey of [false, true]) {
          for (const altKey of [false, true]) {
            for (const metaKey of [false, true]) {
              const press = { pointerType, button, ctrlKey, metaKey, altKey, shiftKey: false };
              const label = JSON.stringify({ selected: selected.tool, ...press });
              const tool = tools.gestureTool(selected, press);

              assert.equal(tool.tool, expectedTool(selected, press), label);
              // Only the tool can change: colour and size are the selection's.
              assert.equal(tool.color, selected.color, label);
              assert.equal(tool.size, selected.size, label);
              assert.equal(tools.picksColor(selected, press), tool.tool === "picker", label);

              const stroke = tools.gestureStroke(selected, press);
              assert.deepEqual(stroke, { ...tools.strokeStyle(tool), tool: tool.tool }, label);
              cases += 1;
            }
          }
        }
      }
    }
  }
  assert.equal(cases, 3 * 3 * buttons.length * 2 * 2 * 2);
});

test("the cases that matter, by name", () => {
  const brush = { tool: "brush", color: "#d63838", size: 12 };
  const mouse = (button, mods = {}) => ({ pointerType: "mouse", button, ctrlKey: false, metaKey: false, ...mods });
  const erases = (press) => tools.gestureStroke(brush, press);
  const white = { color: ERASER.color, width: 12, tool: "eraser" };
  const red = { color: "#d63838", width: 12, tool: "brush" };

  // Ctrl+drag and right-drag: white at the slider's size.
  assert.deepEqual(erases(mouse(0, { ctrlKey: true })), white);
  assert.deepEqual(erases(mouse(2)), white);
  // macOS Ctrl+click: a right-button press with Ctrl (some browsers) or the
  // main button with Ctrl (others). Both erase.
  assert.deepEqual(erases(mouse(2, { ctrlKey: true })), white);
  // A pen: Ctrl with the tip, or the barrel button.
  assert.deepEqual(erases({ pointerType: "pen", button: 0, ctrlKey: true }), white);
  assert.deepEqual(erases({ pointerType: "pen", button: 2 }), white);

  // Cmd is not Ctrl; a plain press draws.
  assert.deepEqual(erases(mouse(0, { metaKey: true })), red);
  assert.deepEqual(erases(mouse(0)), red);
  // Touch has no modifiers here, even with a keyboard's Ctrl held.
  assert.deepEqual(erases({ pointerType: "touch", button: 0, ctrlKey: true }), red);
  // Not a press at all: the selected tool.
  assert.deepEqual(erases(undefined), red);
  assert.deepEqual(erases(null), red);

  // With the eraser selected, everything erases.
  assert.equal(tools.gestureTool({ ...brush, tool: "eraser" }, mouse(0)).tool, "eraser");
});

test("a gesture's eraser never changes the selected tool", () => {
  tools.setDrawTool({ tool: "brush", color: "#1f9a4a", size: 9 });
  const heard = [];
  const stop = tools.onToolChange((tool) => heard.push(tool));

  const press = { pointerType: "mouse", button: 2, ctrlKey: true };
  assert.equal(tools.gestureStroke(tools.currentTool(), press).color, ERASER.color);
  assert.equal(tools.gestureTool(tools.currentTool(), press).tool, "eraser");

  assert.deepEqual(tools.currentTool(), { tool: "brush", color: "#1f9a4a", size: 9 });
  assert.deepEqual(heard, []);
  stop();
});

test("an invalid selection falls back like normalizeTool", () => {
  assert.deepEqual(tools.gestureTool(undefined, { pointerType: "mouse", button: 0 }), { ...DEFAULT_TOOL });
  assert.deepEqual(tools.gestureTool({ tool: "pen", size: 99 }, { pointerType: "mouse", button: 2 }), {
    ...DEFAULT_TOOL,
    tool: "eraser",
    size: MAX_SIZE,
  });
});

// ── The colour picker (eyedropper) ──────────────────────────────────

test("the picker is a tool: valid, kept by the model, drawing like the brush if asked", () => {
  assert.ok(TOOLS.includes("picker"));
  assert.deepEqual(tools.setDrawTool({ tool: "picker" }), { ...DEFAULT_TOOL, tool: "picker" });
  assert.deepEqual(tools.normalizeTool({ tool: "picker", color: "#123456", size: 9 }), {
    tool: "picker",
    color: "#123456",
    size: 9,
  });
  // The engine never draws with it (a pick takes the press), but its style
  // is a valid stroke.
  assert.deepEqual(tools.strokeStyle({ tool: "picker", color: "#123456", size: 9 }), {
    color: "#123456",
    width: 9,
  });
});

test("what picks: the picker's press, and Alt+press with the brush only", () => {
  const mouse = (mods = {}) => ({ pointerType: "mouse", button: 0, ...mods });
  const brush = { tool: "brush", color: "#d63838", size: 12 };
  const picker = { ...brush, tool: "picker" };
  const eraser = { ...brush, tool: "eraser" };

  assert.equal(tools.picksColor(picker, mouse()), true);
  assert.equal(tools.picksColor(picker, { pointerType: "pen", button: 0 }), true);
  // A touch with the picker picks (only modifiers are ignored for touch).
  assert.equal(tools.picksColor(picker, { pointerType: "touch", button: 0 }), true);
  assert.equal(tools.picksColor(brush, mouse({ altKey: true })), true);
  assert.equal(tools.picksColor(brush, { pointerType: "pen", button: 0, altKey: true }), true);

  assert.equal(tools.picksColor(brush, mouse()), false);
  assert.equal(tools.picksColor(eraser, mouse({ altKey: true })), false);
  assert.equal(tools.picksColor(brush, { pointerType: "touch", button: 0, altKey: true }), false);
  // Ctrl and the right button still erase, whatever is selected.
  for (const selected of [brush, picker]) {
    assert.equal(tools.gestureTool(selected, mouse({ ctrlKey: true })).tool, "eraser");
    assert.equal(tools.gestureTool(selected, mouse({ ctrlKey: true, altKey: true })).tool, "eraser");
    assert.equal(tools.gestureTool(selected, { pointerType: "mouse", button: 2, altKey: true }).tool, "eraser");
  }
});

test("after a pick: the tool before the picker, the eraser coming back as the brush", () => {
  // A quick pick (Alt with the brush) keeps the brush.
  assert.equal(tools.toolAfterPick("brush", null), "brush");
  // The picker gives way to the tool used before it.
  assert.equal(tools.toolAfterPick("picker", "brush"), "brush");
  assert.equal(tools.toolAfterPick("picker", "eraser"), "brush");
  // Nothing noted (the page pushed the picker first thing): the brush.
  assert.equal(tools.toolAfterPick("picker", null), "brush");
  assert.equal(tools.toolAfterPick("picker", "picker"), "brush");
  assert.equal(tools.toolAfterPick("picker", "nope"), "brush");
});

test("the tool before the picker is noted whenever the picker is selected", () => {
  tools.setDrawTool({ tool: "eraser" });
  tools.setDrawTool({ tool: "picker" });
  assert.equal(tools.toolBeforePicker(), "eraser");
  // Re-selecting the picker (a page push) doesn't overwrite it.
  tools.setDrawTool({ tool: "picker", size: 30 });
  assert.equal(tools.toolBeforePicker(), "eraser");

  copy.setDrawTool({ tool: "brush" });
  copy.setDrawTool({ tool: "picker" });
  assert.equal(tools.toolBeforePicker(), "brush");
  assert.equal(copy.toolBeforePicker(), "brush");
});
