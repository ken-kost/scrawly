// The colour picker tool (lib/scrawly_web/pages/eyedropper.mjs): what a
// pick does to the tool (the brush in the picked colour, the tool before
// the picker coming back, the eraser as the brush) and to the page (one
// color_picked); which presses it takes from the stroke engine; and the
// swatch beside the pointer: where it goes, when it shows (the picker or
// Alt with the brush, a mouse or a pen, an enabled canvas, not mid-stroke),
// the colour under the pointer, written at most once per animation frame
// and never touching the DOM on frames that don't pick.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

// ── A minimal window and document (as test/js/size_ring.test.mjs) ────

globalThis.window = globalThis;
const listeners = {};
globalThis.addEventListener = (type, fn) => (listeners[type] ||= new Set()).add(fn);
globalThis.removeEventListener = (type, fn) => listeners[type] && listeners[type].delete(fn);
const fire = (type, e) => [...(listeners[type] || [])].forEach((fn) => fn(e));

let frames = [];
let frameRequests = 0;
globalThis.requestAnimationFrame = (fn) => {
  frameRequests += 1;
  frames.push(fn);
  return frames.length;
};
const flushFrame = () => {
  const due = frames;
  frames = [];
  due.forEach((fn) => fn(0));
};

function makeEl(tagName, id, extra = {}) {
  return {
    tagName,
    id,
    attrs: {},
    style: {},
    setAttribute(k, v) {
      this.attrs[k] = String(v);
    },
    removeAttribute(k) {
      delete this.attrs[k];
    },
    getAttribute(k) {
      return k in this.attrs ? this.attrs[k] : null;
    },
    ...extra,
  };
}

// The frame at (100, 50), 880 x 495 px: the 800 x 450 viewBox at 1.1.
const RECT = { left: 100, top: 50, right: 980, bottom: 545, width: 880, height: 495 };
const frame = makeEl("div", null, { getBoundingClientRect: () => RECT });
const svg = makeEl("svg", "game-canvas-svg", {
  // The CTM maps viewBox to client; its inverse, client to viewBox.
  getScreenCTM: () => ({
    a: 1.1,
    b: 0,
    c: 0,
    d: 1.1,
    e: RECT.left,
    f: RECT.top,
    inverse: () => ({ a: 1 / 1.1, b: 0, c: 0, d: 1 / 1.1, e: -RECT.left / 1.1, f: -RECT.top / 1.1 }),
  }),
});
const swatch = makeEl("span", "game-canvas-pick", { parentNode: frame });
const path = { closest: (sel) => (sel === "svg[id]" ? svg : null) };
const elsewhere = { closest: () => null };

const elements = { "game-canvas-svg": svg, "game-canvas-pick": swatch };
let lookups = 0;
globalThis.document = {
  getElementById: (id) => {
    lookups += 1;
    return elements[id] || null;
  },
};

let enabled = true;
let drawing = false;
globalThis.__scrawlyStrokeEngines = new Map([
  ["game-canvas-svg", { isEnabled: () => enabled, isDrawing: () => drawing, gestureStyle: () => null }],
]);

// What the page receives.
const dispatched = [];
globalThis.Hologram = { dispatchAction: (name, target, params) => dispatched.push({ name, target, params }) };

const eye = await import("../../lib/scrawly_web/pages/eyedropper.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const { swatchOffset, pressNow, applyPick, pickPress, SWATCH_SIZE, SWATCH_GAP } = eye;

// The canvas's colour at a viewBox point: red left of x = 400, white right.
const sampled = [];
const sample = (x, y) => {
  sampled.push([x, y]);
  return x < 400 ? "#d63838" : "#ffffff";
};
eye.ensurePickSwatch("game-canvas-svg", "game-canvas-pick", sample);

const move = (x, y, { type = "mouse", target = path, ctrlKey = false, altKey = false } = {}) =>
  fire("pointermove", { clientX: x, clientY: y, pointerType: type, target, ctrlKey, altKey });
const shown = () => swatch.style.visibility === "visible";
const picks = () => dispatched.filter((d) => d.name === "color_picked").map((d) => d.params.color);

beforeEach(() => {
  enabled = true;
  drawing = false;
  dispatched.length = 0;
  tools.resetDrawTool();
  move(300, 300);
  fire("keyup", { key: "Alt", ctrlKey: false, altKey: false });
  flushFrame();
  sampled.length = 0;
});

// ── Placement ────────────────────────────────────────────────────────

test("the swatch sits above and to the right of the pointer, flipped at the frame's edges", () => {
  assert.deepEqual(swatchOffset(100, 100, 880, 495), { x: 100 + SWATCH_GAP, y: 100 - SWATCH_GAP - SWATCH_SIZE });
  // At the right edge: to the left.
  assert.deepEqual(swatchOffset(870, 100, 880, 495), { x: 870 - SWATCH_GAP - SWATCH_SIZE, y: 66 });
  // At the top: below.
  assert.deepEqual(swatchOffset(100, 10, 880, 495), { x: 112, y: 22 });
  // A corner: both.
  assert.deepEqual(swatchOffset(875, 5, 880, 495), { x: 875 - 34, y: 17 });
});

test("the press a pointer would make now: the main button, the keys as held", () => {
  assert.deepEqual(pressNow("pen", true, false), { pointerType: "pen", button: 0, ctrlKey: true, altKey: false });
  assert.deepEqual(pressNow("mouse", undefined, 1), { pointerType: "mouse", button: 0, ctrlKey: false, altKey: false });
});

// ── The pick ─────────────────────────────────────────────────────────

test("a pick: the brush in the colour (lowercase), the page told once", () => {
  tools.setDrawTool({ tool: "picker" });
  assert.equal(applyPick("#D63838", "picker"), "#d63838");
  assert.deepEqual(tools.currentTool(), { ...tools.DEFAULT_TOOL, color: "#d63838" });
  assert.deepEqual(picks(), ["#d63838"]);
  assert.deepEqual(dispatched.map((d) => d.target), ["page"]);
});

test("after the picker the tool used before it, the eraser coming back as the brush", () => {
  tools.setDrawTool({ tool: "eraser" });
  tools.setDrawTool({ tool: "picker" });
  applyPick("#2a6df4", "picker");
  assert.equal(tools.currentTool().tool, "brush");

  // A quick pick (Alt with the brush) keeps the brush.
  applyPick("#16a34a", "brush");
  assert.deepEqual(tools.currentTool(), { ...tools.DEFAULT_TOOL, color: "#16a34a" });
});

test("something that is no colour changes nothing", () => {
  tools.setDrawTool({ tool: "picker" });
  for (const color of [null, undefined, "red", "#fff", 7]) assert.equal(applyPick(color, "picker"), null);
  assert.equal(tools.currentTool().tool, "picker");
  assert.deepEqual(dispatched, []);
});

test("pickPress takes only the presses that pick, with the canvas's context and point", () => {
  const asked = [];
  const take = pickPress((ctx, x, y) => {
    asked.push([ctx, x, y]);
    return "#9333ea";
  });
  const mouse = (mods = {}) => ({ pointerType: "mouse", button: 0, ...mods });

  assert.equal(take("inst", mouse(), [10, 20]), false);
  assert.equal(take("inst", mouse({ ctrlKey: true, altKey: true }), [10, 20]), false);
  assert.deepEqual(asked, []);

  assert.equal(take("inst", mouse({ altKey: true }), [10, 20]), true);
  assert.deepEqual(asked, [["inst", 10, 20]]);
  assert.equal(tools.currentTool().color, "#9333ea");

  tools.setDrawTool({ tool: "picker" });
  assert.equal(take("inst", { pointerType: "touch", button: 0 }, [1, 2]), true);
  assert.equal(take("inst", { pointerType: "mouse", button: 2 }, [1, 2]), false);
});

// ── The swatch ───────────────────────────────────────────────────────

test("with the picker the swatch shows the colour under the pointer, beside it", () => {
  assert.equal(shown(), false);
  tools.setDrawTool({ tool: "picker" });
  flushFrame();
  assert.equal(shown(), true);
  assert.equal(swatch.style.background, "#d63838");
  // (300, 300) client = ((300 - 100) / 1.1, (300 - 50) / 1.1) in the viewBox.
  assert.deepEqual(sampled, [[181.8, 227.3]]);
  assert.equal(swatch.style.transform, "translate3d(212px, 216px, 0)");
  // The canvas's cursor is the crosshair while it shows (app.css).
  assert.equal(svg.getAttribute("data-pick"), "");

  move(600, 300);
  flushFrame();
  assert.equal(swatch.style.background, "#ffffff");

  tools.setDrawTool({ tool: "brush" });
  flushFrame();
  assert.equal(shown(), false);
  assert.equal(svg.getAttribute("data-pick"), null);
});

test("Alt with the brush shows it until Alt comes up; with the eraser, or Ctrl, it doesn't", () => {
  fire("keydown", { key: "Alt", ctrlKey: false, altKey: true });
  flushFrame();
  assert.equal(shown(), true);
  fire("keyup", { key: "Alt", ctrlKey: false, altKey: false });
  flushFrame();
  assert.equal(shown(), false);

  move(310, 300, { altKey: true, ctrlKey: true });
  flushFrame();
  assert.equal(shown(), false);

  tools.setDrawTool({ tool: "eraser" });
  move(320, 300, { altKey: true });
  flushFrame();
  assert.equal(shown(), false);
});

test("never for touch, a viewer's or a switched-off canvas, mid-stroke, or off the canvas", () => {
  tools.setDrawTool({ tool: "picker" });
  flushFrame();
  assert.equal(shown(), true);

  move(300, 300, { type: "touch" });
  flushFrame();
  assert.equal(shown(), false);
  move(300, 300, { type: "pen" });
  flushFrame();
  assert.equal(shown(), true);

  enabled = false;
  move(301, 300);
  flushFrame();
  assert.equal(shown(), false);
  enabled = true;

  drawing = true;
  move(302, 300);
  flushFrame();
  assert.equal(shown(), false);
  drawing = false;

  move(1200, 300, { target: elsewhere });
  flushFrame();
  assert.equal(shown(), false);

  // The pointer left the page.
  move(303, 300);
  flushFrame();
  assert.equal(shown(), true);
  fire("pointerout", { relatedTarget: null });
  flushFrame();
  assert.equal(shown(), false);
});

test("many moves in a frame: one frame, one sample, at the last; unchanged values not rewritten", () => {
  tools.setDrawTool({ tool: "picker" });
  flushFrame();
  sampled.length = 0;
  const before = frameRequests;
  for (let x = 200; x < 260; x += 6) move(x, 300);
  assert.equal(frameRequests, before + 1);
  flushFrame();
  assert.equal(sampled.length, 1);

  // Same colour, new place: only the transform is written.
  const writes = [];
  const style = swatch.style;
  swatch.style = new Proxy(style, {
    set(target, key, value) {
      writes.push(key);
      target[key] = value;
      return true;
    },
  });
  try {
    move(270, 300);
    flushFrame();
    assert.deepEqual(writes, ["transform"]);
  } finally {
    swatch.style = style;
  }
});

test("frames that don't pick touch no DOM once the swatch is hidden (every frame of a stroke)", () => {
  tools.setDrawTool({ tool: "brush" });
  flushFrame();
  lookups = 0;
  for (let i = 0; i < 5; i++) {
    move(300 + i, 300);
    flushFrame();
  }
  assert.equal(lookups, 0);
  assert.deepEqual(sampled, []);
});
