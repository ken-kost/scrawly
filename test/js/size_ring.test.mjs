// The size ring over a canvas (lib/scrawly_web/pages/size_ring.mjs): its
// geometry (the stroke's real width at the canvas's scale), when it shows
// (mouse and pen over an enabled canvas) and hides, and that it is written
// at most once per animation frame, natively, following the tool.
// Run with `node --test test/js/*.test.mjs` (test/scrawly_web/js_unit_test.exs).

import { test, beforeEach } from "node:test";
import assert from "node:assert/strict";

// ── A minimal window and document ────────────────────────────────────

globalThis.window = globalThis;
const listeners = {};
globalThis.addEventListener = (type, fn) => (listeners[type] ||= new Set()).add(fn);
globalThis.removeEventListener = (type, fn) => listeners[type] && listeners[type].delete(fn);
const fire = (type, e) => [...(listeners[type] || [])].forEach((fn) => fn(e));

// Animation frames run only when the test says so.
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

// The canvas frame at (100, 50), 880 x 495 px: the 800 x 450 viewBox at 1.1.
const RECT = { left: 100, top: 50, right: 980, bottom: 545, width: 880, height: 495 };
let scale = 1.1;
const frame = makeEl("div", null, { getBoundingClientRect: () => RECT });
const svg = makeEl("svg", "game-canvas-svg", {
  getScreenCTM: () => ({ a: scale, b: 0, c: 0, d: scale, e: RECT.left, f: RECT.top }),
  getBoundingClientRect: () => RECT,
});
const outer = makeEl("circle");
const inner = makeEl("circle");
const ring = makeEl("svg", "game-canvas-ring", {
  parentNode: frame,
  querySelectorAll: (sel) => (sel === "circle" ? [outer, inner] : []),
});
// A stroke path inside the canvas, and something else on the page.
const path = { closest: (sel) => (sel === "svg[id]" ? svg : null) };
const elsewhere = { closest: () => null };

const elements = { "game-canvas-svg": svg, "game-canvas-ring": ring };
globalThis.document = { getElementById: (id) => elements[id] || null };

// The canvas's stroke engine (stroke_engine.mjs registers it by svg id).
let enabled = true;
globalThis.__scrawlyStrokeEngines = new Map([["game-canvas-svg", { isEnabled: () => enabled }]]);

const sizeRing = await import("../../lib/scrawly_web/pages/size_ring.mjs");
const tools = await import("../../lib/scrawly_web/pages/draw_tools.mjs");
const { ringGeometry, ringShownFor, ringOffset, insideRect, ERASER_DASH, DOT_BELOW } = sizeRing;

const move = (x, y, { type = "mouse", target = path } = {}) =>
  fire("pointermove", { clientX: x, clientY: y, pointerType: type, target });
const shown = () => ring.style.visibility === "visible";
const at = () => ring.style.transform;

sizeRing.ensureSizeRing("game-canvas-svg", "game-canvas-ring");

beforeEach(() => {
  scale = 1.1;
  enabled = true;
  tools.resetDrawTool();
  tools.setDrawTool({ tool: "brush", size: 10 });
  move(500, 300);
  flushFrame();
});

// ── Geometry ─────────────────────────────────────────────────────────

test("the ring's outer edge is the stroke's edge: its diameter is size x scale", () => {
  const g = ringGeometry(10, 1.1, false);
  assert.equal(g.diameter, 11);
  // A 1 px circle of radius r covers r - 0.5 .. r + 0.5.
  assert.equal(g.outer + 0.5, g.diameter / 2);
  assert.equal(g.inner + 0.5, g.diameter / 2 - 1);
  assert.equal(g.box, 13);
  assert.equal(g.center, 6.5);
  assert.equal(g.dash, null);

  for (const [size, s] of [[4, 1.1], [10, 0.4875], [40, 0.45], [40, 1.1], [25, 2]]) {
    const r = ringGeometry(size, s, false);
    assert.ok(Math.abs(r.diameter - size * s) < 1e-9, `${size} at ${s}`);
    assert.equal(r.dot, false);
    assert.ok(Math.abs(2 * (r.outer + 0.5) - r.diameter) < 1e-9, "outer edge = stroke edge");
    assert.ok(r.box >= r.diameter + 2 - 1e-9, "the box holds the ring");
    assert.ok(r.center + r.outer + 0.5 <= r.box, "the ring fits its box");
  }
});

test("a footprint under 4 px is the dot it paints; from 4 px on, two circles", () => {
  assert.equal(DOT_BELOW, 4);
  for (const [size, s] of [[1, 0.45], [1, 1.1], [3, 1.1], [8, 0.45]]) {
    const g = ringGeometry(size, s, true);
    assert.equal(g.dot, true, `${size} at ${s}`);
    // A filled disc as wide as the stroke.
    assert.ok(Math.abs(2 * g.outer - size * s) < 1e-9);
    assert.equal(g.inner, null);
    assert.equal(g.dash, null);
  }

  const smallest = ringGeometry(4, 1, false);
  assert.equal(smallest.dot, false);
  assert.equal(smallest.inner, 0.5);
  assert.equal(ringGeometry(10, 1, false).inner, 3.5);
});

test("the eraser's ring is dashed, the brush's solid", () => {
  assert.equal(ringGeometry(10, 1, true).dash, ERASER_DASH);
  assert.equal(ringGeometry(10, 1, false).dash, null);
});

test("it shows for a mouse and a pen, not for touch", () => {
  assert.equal(ringShownFor("mouse"), true);
  assert.equal(ringShownFor("pen"), true);
  assert.equal(ringShownFor("touch"), false);
  assert.equal(ringShownFor(undefined), false);
});

test("its box is centred on the pointer, in the frame's coordinates", () => {
  assert.deepEqual(ringOffset(500, 300, RECT, 13), { x: 393.5, y: 243.5 });
  assert.equal(insideRect(100, 50, RECT), true);
  assert.equal(insideRect(980, 545, RECT), true);
  assert.equal(insideRect(99, 300, RECT), false);
  assert.equal(insideRect(500, 546, RECT), false);
});

// ── On a canvas ──────────────────────────────────────────────────────

test("over an enabled canvas the ring shows the tool's footprint at the pointer", () => {
  assert.equal(shown(), true);
  assert.equal(ring.style.width, "13px");
  assert.equal(ring.style.height, "13px");
  assert.deepEqual([outer.attrs.cx, outer.attrs.cy, outer.attrs.r], ["6.5", "6.5", "5"]);
  assert.equal(inner.attrs.r, "4");
  assert.equal(outer.attrs["stroke-dasharray"], undefined);
  assert.equal(at(), "translate3d(393.5px, 243.5px, 0)");
  // The canvas shows a crosshair while it is up.
  assert.equal(svg.getAttribute("data-size-ring"), "");
});

test("many moves in a frame: one frame requested, the ring written once, at the last", () => {
  const before = frameRequests;
  for (let i = 0; i < 50; i++) move(200 + i, 200);
  assert.equal(frameRequests - before, 1);
  // Nothing written until the frame.
  assert.equal(at(), "translate3d(393.5px, 243.5px, 0)");

  flushFrame();
  assert.equal(at(), "translate3d(142.5px, 143.5px, 0)");
});

test("it follows the tool without a move: the size, and the eraser dashed", () => {
  tools.setDrawTool({ size: 40 });
  flushFrame();
  assert.equal(ring.style.width, "46px");
  assert.equal(outer.attrs.r, "21.5");

  tools.setDrawTool({ tool: "eraser" });
  flushFrame();
  assert.equal(outer.attrs["stroke-dasharray"], ERASER_DASH);
  assert.equal(inner.attrs["stroke-dasharray"], ERASER_DASH);
  // Same size: the eraser's footprint is the brush's.
  assert.equal(ring.style.width, "46px");

  tools.setDrawTool({ tool: "brush" });
  flushFrame();
  assert.equal(outer.attrs["stroke-dasharray"], undefined);
});

test("the scale is the canvas's: a phone-sized canvas gets a smaller ring", () => {
  // 360 px wide: 0.45 px per unit.
  scale = 0.45;
  tools.setDrawTool({ size: 40 });
  flushFrame();
  // 18 px wide stroke: outer edge at 9 px from the centre.
  assert.equal(ring.style.width, "20px");
  assert.equal(Number(outer.attrs.r) + 0.5, 9);

  // Size 1 there is a 0.45 px dot.
  tools.setDrawTool({ size: 1 });
  flushFrame();
  assert.equal(ring.getAttribute("data-dot"), "");
  assert.equal(outer.attrs.r, "0.225");
  assert.equal(inner.attrs.r, "0");

  tools.setDrawTool({ size: 10 });
  flushFrame();
  assert.equal(ring.getAttribute("data-dot"), null);
  assert.equal(Number(outer.attrs.r) + 0.5, 2.25);
});

test("touch hides it, a pen shows it", () => {
  move(500, 300, { type: "touch" });
  flushFrame();
  assert.equal(shown(), false);
  assert.equal(svg.getAttribute("data-size-ring"), null);

  move(500, 300, { type: "pen" });
  flushFrame();
  assert.equal(shown(), true);
});

test("it hides off the canvas: another element, outside the canvas while captured, off the page", () => {
  move(500, 700, { target: elsewhere });
  flushFrame();
  assert.equal(shown(), false);

  // A stroke goes on outside the canvas: the captured pointer's target is
  // still the svg.
  move(500, 300);
  flushFrame();
  assert.equal(shown(), true);
  move(1200, 300);
  flushFrame();
  assert.equal(shown(), false);

  move(500, 300);
  flushFrame();
  fire("pointerout", { relatedTarget: null });
  flushFrame();
  assert.equal(shown(), false);

  // Out of one element into another of the page is not leaving it.
  move(500, 300);
  fire("pointerout", { relatedTarget: path });
  flushFrame();
  assert.equal(shown(), true);
});

test("it hides while the canvas can't be drawn on, and comes back without a move", () => {
  enabled = false;
  sizeRing.refreshSizeRings();
  flushFrame();
  assert.equal(shown(), false);

  move(510, 300);
  flushFrame();
  assert.equal(shown(), false);

  enabled = true;
  sizeRing.refreshSizeRings();
  flushFrame();
  assert.equal(shown(), true);
  assert.equal(at(), "translate3d(403.5px, 243.5px, 0)");
});

test("an unchanged frame writes nothing", () => {
  const writes = [];
  const style = ring.style;
  ring.style = new Proxy(style, {
    set(target, key, value) {
      writes.push(key);
      target[key] = value;
      return true;
    },
  });
  try {
    move(500, 300);
    flushFrame();
    flushFrame();
    move(501, 300);
    flushFrame();
    assert.deepEqual(writes, ["transform"]);
  } finally {
    ring.style = style;
  }
});
